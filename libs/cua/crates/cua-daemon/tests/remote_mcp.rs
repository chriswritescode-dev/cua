//! The daemon's remote MCP listener (`DaemonHandle::serve_remote_mcp`): a
//! second, non-loopback listener that serves only `/mcp` with its own
//! bearer, distinct from the loopback token, and exposes every Spaces tool
//! except the ones that dial hosts or run agents. Temp dirs only; nothing
//! is created or connected.

use cua_daemon::server::{ServerConfig, start};
use cua_daemon::{Runtime as DaemonRuntime, RuntimeConfig};
use cua_sandbox_core::http::{HttpResponse, ServiceEndpoint, collect, full, open};
use serde_json::{Value, json};
use std::time::Duration;

async fn request(
    endpoint: &ServiceEndpoint,
    method: &str,
    path: &str,
    bearer: Option<&str>,
    session: Option<&str>,
    body: Option<Value>,
) -> HttpResponse {
    let mut headers = vec![("content-type".to_string(), "application/json".to_string())];
    if let Some(b) = bearer {
        headers.push(("authorization".to_string(), format!("Bearer {b}")));
    }
    if let Some(s) = session {
        headers.push(("mcp-session-id".to_string(), s.to_string()));
    }
    let body = full(
        body.map(|b| serde_json::to_vec(&b).unwrap())
            .unwrap_or_default(),
    );
    let resp = open(
        endpoint,
        method,
        path,
        &headers,
        body,
        Some(Duration::from_secs(10)),
    )
    .await
    .unwrap();
    collect(resp).await.unwrap()
}

fn header<'a>(resp: &'a HttpResponse, name: &str) -> Option<&'a str> {
    resp.headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(name))
        .map(|(_, v)| v.as_str())
}

fn initialize() -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "test", "version": "1"},
        },
    })
}

#[tokio::test]
async fn the_remote_listener_serves_only_mcp_with_its_own_token() {
    let dir = tempfile::tempdir().unwrap();
    let runtime = DaemonRuntime::new(RuntimeConfig {
        state_dir: Some(dir.path().join("sandboxes")),
        spaces_home: Some(dir.path().to_path_buf()),
        ..Default::default()
    })
    .unwrap();
    let mut handle = start(
        runtime,
        ServerConfig {
            socket_path: None,
            loopback: Some(([127, 0, 0, 1], 0).into()),
            token: "t0k3n".into(),
            discovery_path: None,
            bridge_ticket_ttl: Duration::from_secs(60),
        },
    )
    .await
    .unwrap();
    let addr = handle
        .serve_remote_mcp(([127, 0, 0, 1], 0).into(), "remote-tok".into())
        .await
        .unwrap();
    let endpoint = ServiceEndpoint {
        url: format!("http://{addr}"),
        headers: vec![],
    };

    // No Authorization, and the loopback token, are both refused.
    let r = request(&endpoint, "POST", "/mcp", None, None, Some(initialize())).await;
    assert_eq!(r.status, 401, "{}", r.text());
    let r = request(
        &endpoint,
        "POST",
        "/mcp",
        Some("t0k3n"),
        None,
        Some(initialize()),
    )
    .await;
    assert_eq!(r.status, 401, "{}", r.text());

    // The remote token initializes and mints a session.
    let r = request(
        &endpoint,
        "POST",
        "/mcp",
        Some("remote-tok"),
        None,
        Some(initialize()),
    )
    .await;
    assert_eq!(r.status, 200, "{}", r.text());
    let session = header(&r, "mcp-session-id")
        .expect("initialize mints an mcp-session-id")
        .to_string();

    let r = request(
        &endpoint,
        "POST",
        "/mcp",
        Some("remote-tok"),
        Some(&session),
        Some(json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})),
    )
    .await;
    assert_eq!(r.status, 200, "{}", r.text());
    let body: Value = serde_json::from_slice(&r.body).unwrap();
    let names: Vec<&str> = body["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|t| t["name"].as_str())
        .collect();
    for want in ["space_bash", "upload", "create_space"] {
        assert!(names.contains(&want), "remote tools/list lacks {want}");
    }
    for denied in [
        "add_space",
        "agent_start",
        "persistent_agent_create",
        "routine_add",
    ] {
        assert!(
            !names.contains(&denied),
            "remote tools/list exposes {denied}"
        );
    }

    // The remote listener serves no other daemon route.
    let r = request(
        &endpoint,
        "GET",
        "/v1/bridge/media",
        Some("remote-tok"),
        None,
        None,
    )
    .await;
    assert_eq!(r.status, 404, "{}", r.text());

    handle.shutdown();
}
