//! MCP JSON-RPC 2.0 protocol types.

use serde::{Deserialize, Serialize};
use serde_json::Value;

// ── Request ──────────────────────────────────────────────────────────────────

/// An incoming JSON-RPC 2.0 request or notification.
#[derive(Debug, Deserialize)]
pub struct Request {
    #[allow(dead_code)]
    pub jsonrpc: String,
    /// Absent on notifications.
    pub id: Option<Value>,
    pub method: String,
    pub params: Option<Value>,
}

impl Request {
    pub fn is_notification(&self) -> bool {
        self.id.is_none()
    }

    pub fn tool_call(&self) -> anyhow::Result<ToolCall> {
        let params = self
            .params
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("missing params"))?;
        let name = params
            .get("name")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("missing tool name"))?
            .to_owned();
        let args = params
            .get("arguments")
            .cloned()
            .unwrap_or(Value::Object(Default::default()));
        Ok(ToolCall { name, args })
    }
}

pub struct ToolCall {
    pub name: String,
    pub args: Value,
}

// ── Response ─────────────────────────────────────────────────────────────────

#[derive(Debug, Serialize)]
pub struct Response {
    pub jsonrpc: &'static str,
    pub id: Value,
    #[serde(flatten)]
    pub body: ResponseBody,
}

#[derive(Debug, Serialize)]
#[serde(untagged)]
pub enum ResponseBody {
    Result { result: Value },
    Error { error: RpcError },
}

#[derive(Debug, Serialize)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl Response {
    pub fn ok(id: Value, result: Value) -> Self {
        Self {
            jsonrpc: "2.0",
            id,
            body: ResponseBody::Result { result },
        }
    }

    pub fn error(id: Value, code: i64, message: impl Into<String>) -> Self {
        Self::error_with_data(id, code, message, None)
    }

    pub fn error_with_data(
        id: Value,
        code: i64,
        message: impl Into<String>,
        data: Option<Value>,
    ) -> Self {
        Self {
            jsonrpc: "2.0",
            id,
            body: ResponseBody::Error {
                error: RpcError {
                    code,
                    message: message.into(),
                    data,
                },
            },
        }
    }

    pub fn parse_error() -> Self {
        Self::error(Value::Null, -32700, "Parse error")
    }

    pub fn method_not_found(id: Value, method: &str) -> Self {
        Self::error(id, -32601, format!("Unknown method: {method}"))
    }
}

// ── Tool result content ───────────────────────────────────────────────────────

/// A single item in the `content` array of a `tools/call` result.
#[derive(Debug, Serialize, Clone)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Content {
    Text {
        text: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        annotations: Option<Value>,
    },
    Image {
        data: String, // base64-encoded PNG
        #[serde(rename = "mimeType")]
        mime_type: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        annotations: Option<Value>,
    },
}

impl Content {
    pub fn text(text: impl Into<String>) -> Self {
        Content::Text {
            text: text.into(),
            annotations: None,
        }
    }

    pub fn image_png(data_base64: String) -> Self {
        Content::Image {
            data: data_base64,
            mime_type: "image/png".into(),
            annotations: None,
        }
    }

    pub fn image_jpeg(data_base64: String) -> Self {
        Content::Image {
            data: data_base64,
            mime_type: "image/jpeg".into(),
            annotations: None,
        }
    }
}

/// The value placed in `result` for a `tools/call` response.
#[derive(Debug, Serialize, Default)]
pub struct ToolResult {
    pub content: Vec<Content>,
    #[serde(rename = "isError", skip_serializing_if = "Option::is_none")]
    pub is_error: Option<bool>,
    #[serde(rename = "structuredContent", skip_serializing_if = "Option::is_none")]
    pub structured_content: Option<Value>,
    /// Rich actuator facts retained inside the daemon. This is deliberately
    /// skipped by serde so the nonbreaking truth-layer migration cannot alter
    /// the MCP result envelope or its legacy structured payload.
    #[serde(skip)]
    pub action_record: Option<crate::action_record::ActionExecutionRecord>,
}

impl ToolResult {
    pub fn text(msg: impl Into<String>) -> Self {
        Self {
            content: vec![Content::text(msg)],
            ..Default::default()
        }
    }

    pub fn error(msg: impl Into<String>) -> Self {
        Self {
            content: vec![Content::text(msg)],
            is_error: Some(true),
            ..Default::default()
        }
    }

    pub fn with_structured(mut self, v: Value) -> Self {
        self.structured_content = Some(v);
        self
    }

    pub fn with_action_record(
        mut self,
        record: crate::action_record::ActionExecutionRecord,
    ) -> Self {
        self.action_record = Some(record);
        self
    }
}

// ── Initialize result ─────────────────────────────────────────────────────────

pub fn initialize_result() -> Value {
    serde_json::json!({
        "protocolVersion": "2025-06-18",
        "capabilities": crate::mcp_wire::server_capabilities(),
        "serverInfo": { "name": "cua-driver", "version": env!("CARGO_PKG_VERSION") },
        "instructions": agent_instructions()
    })
}

/// MCP `instructions` (`InitializeResult.instructions`) sent to every
/// connecting client. The spec frames this as a "hint... MAY be added
/// to the system prompt" — eager, every-turn cost. We keep it under
/// the community-recommended ~200-word ceiling and host the long-form
/// workflow in `Skills/cua-driver/SKILL.md`.
///
/// Templated per-host: the accessibility-tree provider name (AX on
/// macOS, UIA on Windows, AT-SPI on Linux) is injected so a connecting
/// agent only sees the path that applies, not all three. Same pattern
/// Goose uses in its `ComputerController` extension and Open
/// Interpreter uses for its system message.
fn agent_instructions() -> String {
    // macOS needs no platform pointer: its permission line below names MACOS.md.
    let (tree_kind, platform_skill_pointer) = if cfg!(target_os = "macos") {
        ("AX", "")
    } else if cfg!(target_os = "windows") {
        (
            "UIA",
            ", WINDOWS.md (UIA tree, UWP/ApplicationFrameHost hosting, Session 0 isolation)",
        )
    } else {
        (
            "AT-SPI",
            ", LINUX.md (X11/Wayland status, AT-SPI bus, BETA-level support)",
        )
    };

    // macOS only: Cua Driver's own TCC prompts have one narrow, owner-gated
    // exception to "system prompts belong to the user"; the steps and
    // guardrails live in MACOS.md ("Install and approve permissions").
    let permission_line = if cfg!(target_os = "macos") {
        "\n\nmacOS: if `check_permissions` shows Accessibility or Screen Recording off, ask the user; approve Cua Driver's own prompts only if the owner explicitly authorized it (MACOS.md)."
    } else {
        ""
    };

    // Only point at run_script when this driver offers it.
    #[cfg(feature = "script")]
    let script_enabled = crate::script_tool::enabled();
    #[cfg(not(feature = "script"))]
    let script_enabled = false;
    let script_line = if script_enabled {
        " Loops, branches or retries: one `run_script` call."
    } else {
        ""
    };

    format!(
        r#"cua-driver: background GUI automation. No shell: for non-GUI outcomes use an app API/SDK, CLI or filesystem and read the result back there.

1. `list_windows({{app:"Name"}})` or `launch_app` for `pid` and `window_id`.
2. Read narrowly: `get_window_state` with `query:"Save"`. Re-read with `since:"latest"`.
3. Act by `element_token` ({tree_kind}): row `[N]` is `<snapshot_id>:N`. Pixels only for surfaces missing from the tree.
4. Act through `run_steps({{steps:[{{tool,args}}],observe:{{}}}})`, even for one step: stops at the first failure, returns what changed.{script_line}
5. Verify at checkpoints, not after every action: `verify_state(pid, window_id, expect)`. `unknown` and `effect:"unverifiable"` are not success.

Use the narrowest semantic route first: `set_window_frame` plus `list_windows` for geometry, typed browser tools for pages. Stay in the background; `delivery_mode:"foreground"` only if refused or unverifiable.

Chrome/Edge/Brave page: `get_browser_state({{pid, window_id}})`, its `detail.next_call` (`browser_prepare`) if refused, then `browser_click`/`browser_type`/`browser_pointer` (hover, drag); never desktop pointer tools.

`start_session` is optional; repeat a short `session` label on every call that accepts it. On continuation/recent-work, call `history_status`; if ready, make one bounded initial `history_query` before broad discovery.{permission_line}

Guides: `get_guide({{topic}})` (drag, browser, permissions, batching, menus), `skill://cua-driver/SKILL.md`{platform_skill_pointer}."#
    )
}

#[cfg(test)]
mod image_mime_type_tests {
    use super::Content;

    /// Surface 7 contract: image parts serialize an explicit `mimeType` field
    /// (not `mime_type`, not `format`) so MCP consumers don't have to sniff
    /// magic bytes off the base64 PNG/JPEG to know what they're holding.
    /// This locks in the JSON shape — any rename or drop breaks here first.
    #[test]
    fn image_png_serializes_with_explicit_mime_type() {
        let c = Content::image_png("ZmFrZQ==".into());
        let v = serde_json::to_value(&c).expect("serialize");
        assert_eq!(v.get("type").and_then(|t| t.as_str()), Some("image"));
        assert_eq!(
            v.get("mimeType").and_then(|t| t.as_str()),
            Some("image/png")
        );
        assert_eq!(v.get("data").and_then(|t| t.as_str()), Some("ZmFrZQ=="));
    }

    #[test]
    fn image_jpeg_serializes_with_explicit_mime_type() {
        let c = Content::image_jpeg("ZmFrZQ==".into());
        let v = serde_json::to_value(&c).expect("serialize");
        assert_eq!(v.get("type").and_then(|t| t.as_str()), Some("image"));
        assert_eq!(
            v.get("mimeType").and_then(|t| t.as_str()),
            Some("image/jpeg")
        );
    }

    /// Text parts must not grow a mimeType field — the field belongs to
    /// image parts only. Guards against an accidental serde_json renamer
    /// that emits a shared shape across the enum.
    #[test]
    fn text_does_not_carry_mime_type() {
        let c = Content::text("hi");
        let v = serde_json::to_value(&c).expect("serialize");
        assert_eq!(v.get("type").and_then(|t| t.as_str()), Some("text"));
        assert!(
            v.get("mimeType").is_none(),
            "text content must not carry mimeType"
        );
    }
}

#[cfg(test)]
mod action_record_wire_tests {
    use super::ToolResult;
    use crate::action_record::{
        ActionEffect, ActionExecutionRecord, ActionTransport, ActualDelivery, RequestedDelivery,
    };

    #[test]
    fn internal_action_record_never_changes_mcp_serialization() {
        let legacy = serde_json::json!({
            "path": "cgevent",
            "verified": false,
            "effect": "unverifiable",
        });
        let plain = ToolResult::text("clicked").with_structured(legacy.clone());
        let with_truth = ToolResult::text("clicked")
            .with_structured(legacy)
            .with_action_record(
                ActionExecutionRecord::builder(
                    ActionEffect::Unverifiable,
                    ActionTransport::MacosCgEventPid,
                    RequestedDelivery::Background,
                )
                .actual_delivery(ActualDelivery::Background)
                .build()
                .expect("valid action record"),
            );
        assert_eq!(
            serde_json::to_value(plain).expect("serialize plain result"),
            serde_json::to_value(with_truth).expect("serialize result with internal truth"),
        );
    }
}

#[cfg(test)]
mod agent_instruction_tests {
    use super::{agent_instructions, initialize_result};

    #[test]
    fn instructions_route_structured_and_visual_verification_to_the_right_owner() {
        let instructions = agent_instructions();
        assert!(instructions.contains("verify_state"));
        assert!(instructions.contains("`unknown` and `effect:\"unverifiable\"` are not success"));
        assert!(instructions.contains("app API/SDK"));
        assert!(instructions.contains("read the result back there"));
        assert!(instructions.contains("narrowest semantic route first"));
        assert!(instructions.contains("`set_window_frame` plus `list_windows`"));
        assert!(instructions.contains("typed browser tools"));
        assert!(instructions.contains("`get_browser_state({pid, window_id})`"));
        assert!(instructions.contains("`detail.next_call` (`browser_prepare`)"));
        assert!(
            instructions.contains("`browser_pointer` (hover, drag); never desktop pointer tools")
        );
        assert!(instructions.contains("No shell"));
        // The efficient workflow must be front-loaded: targeted read, act by
        // token, verify at checkpoints.
        assert!(instructions.contains("`query:\"Save\"`"));
        assert!(instructions.contains("Act by `element_token`"));
        assert!(instructions.contains("Verify at checkpoints, not after every action"));
        assert!(
            instructions.find("Read narrowly") < instructions.find("Act by `element_token`"),
            "the targeted read must precede acting"
        );
        #[cfg(feature = "script")]
        if crate::script_tool::enabled() {
            assert!(instructions.contains("one `run_script` call"));
        }
        assert!(
            instructions.split_whitespace().count() <= 200,
            "initialize instructions should stay within the documented context budget"
        );
    }

    #[test]
    fn instructions_point_at_get_guide_and_keep_the_skill_resource() {
        let instructions = agent_instructions();
        assert!(instructions.contains("`get_guide({topic})`"));
        for topic in crate::guide::topic_names()
            .into_iter()
            .filter(|topic| *topic != "overview")
        {
            assert!(
                instructions.contains(topic),
                "instructions should name the {topic} topic"
            );
        }
        assert!(instructions.contains("`skill://cua-driver/SKILL.md`"));
        assert!(instructions.split_whitespace().count() <= 200);
    }

    #[test]
    fn macos_instructions_gate_permission_approval_on_owner_authorization() {
        let instructions = agent_instructions();
        let has_line = instructions.contains("Cua Driver's own prompts");
        assert_eq!(
            has_line,
            cfg!(target_os = "macos"),
            "only the macOS instructions mention TCC prompts"
        );
        if has_line {
            // Keeps the narrow exception narrow: ask first, own prompts only,
            // explicit owner authorization; MACOS.md holds the detail.
            assert!(instructions.contains("ask the user"));
            assert!(instructions.contains(
                "approve Cua Driver's own prompts only if the owner explicitly authorized it"
            ));
            assert!(instructions.contains("(MACOS.md)"));
            assert!(instructions.contains("`check_permissions`"));
        }
    }

    #[test]
    fn initialize_instructions_describe_implicit_session_lifecycle() {
        let result = initialize_result();
        let instructions = result["instructions"]
            .as_str()
            .expect("initialize result should carry agent instructions");

        assert!(instructions.contains("`start_session` is optional"));
        assert!(
            instructions.contains("repeat a short `session` label on every call that accepts it")
        );
        assert!(
            !instructions.contains("`start_session(session)` once"),
            "initialize instructions must not require explicit session setup"
        );
    }

    #[test]
    fn initialize_instructions_conditionally_consult_history_before_discovery() {
        let instructions = initialize_result()["instructions"]
            .as_str()
            .expect("initialize result should carry agent instructions")
            .to_owned();

        assert!(instructions.contains("continuation/recent-work"));
        let status = instructions.find("call `history_status`").unwrap();
        let bounded_query = instructions
            .find("one bounded initial `history_query`")
            .unwrap();
        let discovery = instructions.find("broad discovery").unwrap();
        assert!(status < bounded_query);
        assert!(bounded_query < discovery);
        assert!(instructions.contains("if ready"));
        assert!(instructions.split_whitespace().count() <= 200);
    }
}
