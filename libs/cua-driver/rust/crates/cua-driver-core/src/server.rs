//! Shared MCP request dispatch.

use tracing::warn;

use crate::authorization::authorize_tool_call;
use crate::mcp_result::{conforming_tool_result, tool_error_result};
use crate::protocol::{initialize_result, Request, Response};
use crate::tool::ToolRegistry;

/// Runtime contract consumed by protocol adapters such as MCP.
///
/// The standalone server implements this with the public Cua Driver SDK; the
/// `ToolRegistry` implementation remains for core-level tests and embedders.
/// Keeping the protocol dependent on this small contract prevents transports
/// from reaching through the SDK into its private platform registry.
#[async_trait::async_trait]
pub trait ToolProvider: Send + Sync {
    fn tools_list(&self) -> serde_json::Value;
    fn is_known_tool(&self, _name: &str) -> bool {
        true
    }

    async fn invoke_tool(
        &self,
        name: &str,
        arguments: serde_json::Value,
    ) -> Result<serde_json::Value, String>;
}

#[async_trait::async_trait]
impl ToolProvider for ToolRegistry {
    fn tools_list(&self) -> serde_json::Value {
        ToolRegistry::tools_list(self)
    }

    fn is_known_tool(&self, name: &str) -> bool {
        ToolRegistry::is_known_tool(self, name)
    }

    async fn invoke_tool(
        &self,
        name: &str,
        arguments: serde_json::Value,
    ) -> Result<serde_json::Value, String> {
        serde_json::to_value(self.invoke_from_trusted_adapter(name, arguments).await)
            .map_err(|error| format!("Serialize error: {error}"))
    }
}

/// Dispatch one MCP JSON-RPC request against the registry (initialize /
/// tools/list / tools/call). Shared by the stdio loop above and the
/// daemon's HTTP transport (`cua-driver`'s `mcp_http`) so both speak the
/// exact same MCP semantics.
pub async fn handle_request(
    req: Request,
    id: serde_json::Value,
    provider: &dyn ToolProvider,
) -> Response {
    handle_request_inner(req, id, provider, None).await
}

/// Dispatch one MCP request with a transport identity proved by the local
/// adapter rather than supplied by the MCP client.
///
/// The ordinary untrusted entry point above must continue to discard every
/// reserved argument. Direct stdio and authenticated HTTP each own a transport
/// lease, so their adapters pass that lease here after parsing the untrusted
/// request. The inner boundary sanitizes caller claims first and then stamps
/// this trusted owner onto both implicit and explicitly named lifecycle
/// sessions.
pub async fn handle_request_with_transport_session(
    req: Request,
    id: serde_json::Value,
    provider: &dyn ToolProvider,
    transport_session: &str,
) -> Response {
    handle_request_inner(req, id, provider, Some(transport_session)).await
}

async fn handle_request_inner(
    req: Request,
    id: serde_json::Value,
    provider: &dyn ToolProvider,
    transport_session: Option<&str>,
) -> Response {
    let era = match crate::mcp_wire::classify_request(&req) {
        Ok(era) => era,
        Err(response) => return response,
    };
    if req.method == "tools/call" {
        if let Err(response) =
            crate::mcp_wire::validate_tool_call(&req, id.clone(), era, &provider.tools_list())
        {
            return response;
        }
    }
    let method = req.method.clone();
    let response =
        if let Some(response) = crate::mcp_wire::handle_metadata_request(&req, id.clone()) {
            response
        } else {
            dispatch_request(req, id, provider, transport_session, era).await
        };
    crate::mcp_wire::finish_response(era, &method, response)
}

async fn dispatch_request(
    req: Request,
    id: serde_json::Value,
    provider: &dyn ToolProvider,
    transport_session: Option<&str>,
    era: crate::mcp_wire::ProtocolEra,
) -> Response {
    match req.method.as_str() {
        "initialize" if era == crate::mcp_wire::ProtocolEra::Legacy => {
            Response::ok(id, initialize_result())
        }

        "tools/list" => Response::ok(id, provider.tools_list()),

        "tools/call" => match req.tool_call() {
            Err(e) => Response::error(id, -32602, format!("Invalid params: {e}")),
            Ok(mut call) => {
                crate::tool_args::sanitize_reserved_args(&mut call.args);
                if let Err(error) = authorize_tool_call(&call.name, &call.args) {
                    return Response::ok(
                        id,
                        conforming_tool_result(
                            &call.name,
                            tool_error_result(
                                error.to_string(),
                                serde_json::json!({"code": "permission_denied"}),
                            ),
                        ),
                    );
                }

                if !provider.is_known_tool(&call.name) {
                    return Response::ok(
                        id,
                        tool_error_result(
                            format!("Unknown tool: {}", call.name),
                            serde_json::json!({"code": "unknown_tool"}),
                        ),
                    );
                }

                let public_session = call
                    .args
                    .get("session")
                    .and_then(serde_json::Value::as_str)
                    .filter(|session| !session.is_empty())
                    .map(str::to_owned);
                if let Some(arguments) = call.args.as_object_mut() {
                    if let Some(session) = public_session.as_deref().or(transport_session) {
                        arguments.insert(
                            "_session_id".to_owned(),
                            serde_json::Value::String(session.to_owned()),
                        );
                    }
                    if let Some(owner) = transport_session.or(public_session.as_deref()) {
                        arguments.insert(
                            "_transport_session_id".to_owned(),
                            serde_json::Value::String(owner.to_owned()),
                        );
                    }
                }
                if call.name == "browser_download" {
                    if let Some(arguments) = call.args.as_object_mut() {
                        arguments.insert(
                            crate::browser::download::MCP_HOST_DOWNLOAD_APPROVAL_ARG.to_owned(),
                            serde_json::Value::Bool(true),
                        );
                    }
                }

                // Both arms answer through the shared boundary, so a tool
                // payload and an invocation failure are held to the same
                // advertised `outputSchema`.
                let result = match provider.invoke_tool(&call.name, call.args).await {
                    Ok(result) => result,
                    Err(error) => tool_error_result(error, serde_json::json!({"exit_code": 1})),
                };
                Response::ok(id, conforming_tool_result(&call.name, result))
            }
        },

        other => {
            warn!(method = other, "unknown method");
            Response::method_not_found(id, other)
        }
    }
}

#[cfg(test)]
mod dispatch_contract_tests {
    //! The boundary itself is unit-tested in `crate::mcp_result`; these pin
    //! that `tools/call` dispatch actually routes through it, on the path a
    //! strict MCP client exercises.

    use super::*;
    use crate::protocol::ResponseBody;
    use cua_driver_contract::{advertised_tool_output_schema, TOOL_INVOCATION_FAILED_CODE};

    struct NeverInvokeProvider;

    #[async_trait::async_trait]
    impl ToolProvider for NeverInvokeProvider {
        fn is_known_tool(&self, name: &str) -> bool {
            name == "get_config"
        }

        fn tools_list(&self) -> serde_json::Value {
            serde_json::json!({"tools": [{"name": "get_config"}]})
        }

        async fn invoke_tool(
            &self,
            _name: &str,
            _arguments: serde_json::Value,
        ) -> Result<serde_json::Value, String> {
            panic!("invalid requests must not execute tools")
        }
    }

    #[tokio::test]
    async fn modern_invalid_requests_never_execute_tools() {
        for (version, capabilities, name, arguments, expected_code) in [
            (
                "2026-07-28",
                serde_json::json!({}),
                "unknown",
                serde_json::json!({}),
                -32602,
            ),
            (
                "2026-07-28",
                serde_json::json!({}),
                "get_config",
                serde_json::json!([]),
                -32602,
            ),
            (
                "2026-07-28",
                serde_json::Value::Null,
                "get_config",
                serde_json::json!({}),
                -32602,
            ),
            (
                "unknown",
                serde_json::json!({}),
                "get_config",
                serde_json::json!({}),
                -32022,
            ),
        ] {
            let req = serde_json::from_value(serde_json::json!({
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": {"name": name, "arguments": arguments, "_meta": {
                    "io.modelcontextprotocol/protocolVersion": version,
                    "io.modelcontextprotocol/clientCapabilities": capabilities
                }}
            }))
            .unwrap();
            let response = handle_request(req, serde_json::json!(1), &NeverInvokeProvider).await;
            let wire = serde_json::to_value(response).unwrap();
            assert_eq!(wire["error"]["code"], expected_code);
        }
    }

    struct StubProvider(Result<serde_json::Value, String>);

    #[async_trait::async_trait]
    impl ToolProvider for StubProvider {
        fn is_known_tool(&self, _name: &str) -> bool {
            true
        }

        fn tools_list(&self) -> serde_json::Value {
            serde_json::json!({"tools": []})
        }

        async fn invoke_tool(
            &self,
            _name: &str,
            _arguments: serde_json::Value,
        ) -> Result<serde_json::Value, String> {
            self.0.clone()
        }
    }

    fn call_request(name: &str) -> Request {
        serde_json::from_value(serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": { "name": name, "arguments": {} }
        }))
        .expect("request parses")
    }

    fn result_of(response: Response) -> serde_json::Value {
        match response.body {
            ResponseBody::Result { result } => result,
            ResponseBody::Error { error } => panic!("expected a result, got {}", error.message),
        }
    }

    #[track_caller]
    fn assert_conforms(tool: &str, structured: &serde_json::Value) {
        let schema = advertised_tool_output_schema(tool).expect("tool advertises a schema");
        assert!(
            jsonschema::validator_for(&schema)
                .expect("schema compiles")
                .is_valid(structured),
            "advertised schema rejected {structured}"
        );
    }

    /// Reverting the boundary call fails this with the bug as the message:
    /// the advertised schema rejects the bare `{"exit_code": 1}` diagnostic.
    #[tokio::test]
    async fn an_invocation_failure_is_dispatched_as_a_conforming_refusal() {
        let provider = StubProvider(Err("daemon transport closed".to_owned()));

        let result =
            result_of(handle_request(call_request("click"), serde_json::json!(1), &provider).await);

        assert_conforms("click", &result["structuredContent"]);
        // The diagnostic survives the normalization; only the marker is added.
        assert_eq!(result["structuredContent"]["exit_code"], 1);
        assert_eq!(
            result["structuredContent"]["code"],
            TOOL_INVOCATION_FAILED_CODE
        );
    }

    /// The class of failure the two `exit_code` paths were only one instance
    /// of: a provider result that is invalid under the advertised schema no
    /// longer reaches the client as a success.
    #[tokio::test]
    async fn a_provider_success_that_violates_the_schema_is_replaced() {
        let provider = StubProvider(Ok(serde_json::json!({"content": [], "isError": false})));

        let result =
            result_of(handle_request(call_request("click"), serde_json::json!(1), &provider).await);

        assert_conforms("click", &result["structuredContent"]);
        assert_eq!(result["isError"], true);
        assert_eq!(
            result["structuredContent"]["code"],
            crate::mcp_result::TOOL_OUTPUT_INVALID_CODE
        );
    }
}
