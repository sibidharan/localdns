//! LocalDNS Windows helper service.
//!
//! A minimal NRPT scribe: the unprivileged GUI sends declarative sync requests
//! (the desired set of zones) over `\\.\pipe\LocalDNSHelper`; this LocalSystem
//! service re-derives the writes itself against the registry and applies them
//! through PowerShell's DnsClient cmdlets. The privileged surface is tiny:
//! - only rules whose Comment is "LocalDNS" are ever modified or removed;
//! - zone names are grammar-validated before any command interpolation;
//! - the service is demand-start and stops itself after 2 minutes idle,
//!   so no privileged process routinely runs.
//!
//! Install (done by the app installer, elevated):
//!   sc.exe create localdns-helper binPath= "...\localdns-helper.exe" start= demand
//!   sc.exe sdset  localdns-helper  <SDDL granting INTERACTIVE start rights>
//! Uninstall: localdns-helper.exe --unregister-all && sc.exe delete localdns-helper

#[cfg(windows)]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Elevated CLI mode used by the uninstaller: clean up and exit.
    if std::env::args().any(|a| a == "--unregister-all") {
        let outcome = service::nrpt::unregister_all();
        println!("{}", serde_json::to_string(&outcome)?);
        return Ok(());
    }
    service::run()
}

#[cfg(not(windows))]
fn main() {
    eprintln!("localdns-helper is a Windows service; nothing to do on this OS.");
}

#[cfg(windows)]
mod service {
    use std::ffi::OsString;
    use std::sync::mpsc;
    use std::time::Duration;

    use windows_service::service::{
        ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
        ServiceType,
    };
    use windows_service::service_control_handler::{self, ServiceControlHandlerResult};
    use windows_service::{define_windows_service, service_dispatcher};

    pub const SERVICE_NAME: &str = "localdns-helper";
    /// Self-stop after this much idle time — demand-start, no resident root.
    const IDLE_TIMEOUT: Duration = Duration::from_secs(120);

    define_windows_service!(ffi_service_main, service_main);

    pub fn run() -> Result<(), Box<dyn std::error::Error>> {
        service_dispatcher::start(SERVICE_NAME, ffi_service_main)?;
        Ok(())
    }

    fn service_main(_arguments: Vec<OsString>) {
        let (shutdown_tx, shutdown_rx) = mpsc::channel();

        let status_handle = match service_control_handler::register(SERVICE_NAME, move |control| {
            match control {
                ServiceControl::Stop => {
                    let _ = shutdown_tx.send(());
                    ServiceControlHandlerResult::NoError
                }
                ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
                _ => ServiceControlHandlerResult::NotImplemented,
            }
        }) {
            Ok(handle) => handle,
            Err(_) => return,
        };

        let set_state = |state: ServiceState| {
            let _ = status_handle.set_service_status(ServiceStatus {
                service_type: ServiceType::OWN_PROCESS,
                current_state: state,
                controls_accepted: if state == ServiceState::Running {
                    ServiceControlAccept::STOP
                } else {
                    ServiceControlAccept::empty()
                },
                exit_code: ServiceExitCode::Win32(0),
                checkpoint: 0,
                wait_hint: Duration::from_secs(5),
                process_id: None,
            });
        };

        set_state(ServiceState::Running);

        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build();
        if let Ok(runtime) = runtime {
            runtime.block_on(pipe::serve(shutdown_rx, IDLE_TIMEOUT));
        }

        set_state(ServiceState::Stopped);
    }

    pub(crate) mod pipe {
        use std::sync::mpsc;
        use std::time::Duration;

        use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
        use tokio::net::windows::named_pipe::{NamedPipeServer, ServerOptions};

        use localdns_platform::windows::PIPE_PATH;

        use super::nrpt;
        use super::sddl;

        /// Accept loop with an idle self-stop. One request/response line per
        /// connection round; the GUI reconnects per operation.
        pub async fn serve(shutdown: mpsc::Receiver<()>, idle_timeout: Duration) {
            let mut first = true;
            loop {
                if shutdown.try_recv().is_ok() {
                    return;
                }
                let server = match create_instance(first) {
                    Ok(server) => server,
                    Err(_) => return,
                };
                first = false;

                tokio::select! {
                    connected = server.connect() => {
                        if connected.is_ok() {
                            handle_connection(server).await;
                        }
                    }
                    _ = tokio::time::sleep(idle_timeout) => return, // idle: self-stop
                }
            }
        }

        fn create_instance(first: bool) -> std::io::Result<NamedPipeServer> {
            let attributes = sddl::pipe_security_attributes()?;
            let mut options = ServerOptions::new();
            options.first_pipe_instance(first);
            // SAFETY: `attributes` owns a valid SECURITY_ATTRIBUTES whose
            // descriptor lives until after creation returns.
            unsafe { options.create_with_security_attributes_raw(PIPE_PATH, attributes.as_ptr()) }
        }

        async fn handle_connection(server: NamedPipeServer) {
            let (reader, mut writer) = tokio::io::split(server);
            let mut lines = BufReader::new(reader).lines();
            // One JSON-line request per connection; respond and disconnect.
            if let Ok(Some(line)) = lines.next_line().await {
                let response = nrpt::handle_request(&line);
                let mut payload = serde_json::to_string(&response)
                    .unwrap_or_else(|_| r#"{"ok":false,"error":"encode failure"}"#.into());
                payload.push('\n');
                let _ = writer.write_all(payload.as_bytes()).await;
                let _ = writer.flush().await;
            }
        }
    }

    /// SDDL → SECURITY_ATTRIBUTES for the pipe: interactive users read/write,
    /// SYSTEM and Administrators full control. Without this, a LocalSystem-
    /// created pipe rejects ordinary users.
    pub(crate) mod sddl {
        use std::ptr;

        use windows::core::PCWSTR;
        use windows::Win32::Security::Authorization::{
            ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
        };
        use windows::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};

        const PIPE_SDDL: &str = "D:(A;;GRGW;;;IU)(A;;FA;;;SY)(A;;FA;;;BA)";

        pub struct OwnedSecurityAttributes {
            attributes: Box<SECURITY_ATTRIBUTES>,
            descriptor: PSECURITY_DESCRIPTOR,
        }

        impl OwnedSecurityAttributes {
            pub fn as_ptr(&self) -> *mut std::ffi::c_void {
                &*self.attributes as *const SECURITY_ATTRIBUTES as *mut std::ffi::c_void
            }
        }

        impl Drop for OwnedSecurityAttributes {
            fn drop(&mut self) {
                if !self.descriptor.0.is_null() {
                    // SAFETY: descriptor was allocated by the conversion call.
                    unsafe {
                        let _ = windows::Win32::Foundation::LocalFree(Some(
                            windows::Win32::Foundation::HLOCAL(self.descriptor.0),
                        ));
                    }
                }
            }
        }

        pub fn pipe_security_attributes() -> std::io::Result<OwnedSecurityAttributes> {
            let sddl_wide: Vec<u16> = PIPE_SDDL.encode_utf16().chain(std::iter::once(0)).collect();
            let mut descriptor = PSECURITY_DESCRIPTOR(ptr::null_mut());
            // SAFETY: valid NUL-terminated wide string; descriptor out-pointer.
            unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    PCWSTR(sddl_wide.as_ptr()),
                    SDDL_REVISION_1,
                    &mut descriptor,
                    None,
                )
            }
            .map_err(|e| std::io::Error::other(format!("SDDL conversion failed: {e}")))?;

            let attributes = Box::new(SECURITY_ATTRIBUTES {
                nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: descriptor.0,
                bInheritHandle: false.into(),
            });
            Ok(OwnedSecurityAttributes {
                attributes,
                descriptor,
            })
        }
    }

    pub(crate) mod nrpt {
        use std::collections::BTreeSet;
        use std::process::Command;

        use serde::{Deserialize, Serialize};

        use localdns_platform::windows::{namespaces_for, read_local_rules, NrptRule};

        #[derive(Deserialize)]
        #[serde(tag = "op", rename_all = "snake_case")]
        enum Request {
            Sync {
                zones: BTreeSet<String>,
                nameserver: String,
            },
            UnregisterAll,
            Ping,
        }

        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        pub struct Response {
            pub ok: bool,
            pub changed: bool,
            #[serde(skip_serializing_if = "Option::is_none")]
            pub error: Option<String>,
        }

        impl Response {
            fn ok(changed: bool) -> Self {
                Self {
                    ok: true,
                    changed,
                    error: None,
                }
            }
            fn fail(error: String) -> Self {
                Self {
                    ok: false,
                    changed: false,
                    error: Some(error),
                }
            }
        }

        pub fn handle_request(line: &str) -> Response {
            match serde_json::from_str::<Request>(line) {
                Ok(Request::Ping) => Response::ok(false),
                Ok(Request::Sync { zones, nameserver }) => sync(&zones, &nameserver),
                Ok(Request::UnregisterAll) => unregister_all(),
                Err(error) => Response::fail(format!("bad request: {error}")),
            }
        }

        /// Zone grammar gate before ANY command interpolation: reuse the app's
        /// own validator (lowercase letters, digits, hyphens, ≥2 labels).
        fn valid_zone(zone: &str) -> bool {
            localdns_core::validation::pattern_error(zone).is_none()
        }

        fn valid_guid_key(key: &str) -> bool {
            let inner = key.strip_prefix('{').and_then(|k| k.strip_suffix('}'));
            matches!(inner, Some(guid) if guid.len() == 36
                && guid.chars().all(|c| c.is_ascii_hexdigit() || c == '-'))
        }

        fn valid_nameserver(server: &str) -> bool {
            server.parse::<std::net::Ipv4Addr>().is_ok()
        }

        fn owned_rules() -> Vec<NrptRule> {
            read_local_rules().into_iter().filter(NrptRule::is_ours).collect()
        }

        /// Declarative sync: desired zones in, registry diffed here, only
        /// Comment-tagged rules touched. Batched into one PowerShell run.
        pub fn sync(zones: &BTreeSet<String>, nameserver: &str) -> Response {
            if !valid_nameserver(nameserver) {
                return Response::fail("invalid nameserver".into());
            }
            let invalid: Vec<&String> = zones.iter().filter(|z| !valid_zone(z)).collect();
            if !invalid.is_empty() {
                return Response::fail(format!("invalid zone name(s): {invalid:?}"));
            }

            let owned = owned_rules();
            let mut script = String::from("$ErrorActionPreference = 'Stop'\n");
            let mut changed = false;

            // Remove owned rules that are stale or no longer desired.
            let mut keep = BTreeSet::new();
            for rule in &owned {
                let zone = rule.zone().unwrap_or_default();
                let expected: [String; 2] = namespaces_for(&zone);
                let current_ok = zones.contains(&zone)
                    && rule.servers == nameserver
                    && rule.namespaces.len() == 2
                    && expected.iter().all(|ns| rule.namespaces.contains(ns));
                if current_ok {
                    keep.insert(zone);
                } else if valid_guid_key(&rule.key) {
                    script.push_str(&format!(
                        "Remove-DnsClientNrptRule -Name '{}' -Force\n",
                        rule.key
                    ));
                    changed = true;
                }
            }

            // Install missing zones.
            for zone in zones {
                if keep.contains(zone) {
                    continue;
                }
                let [suffix, apex] = namespaces_for(zone);
                script.push_str(&format!(
                    "Add-DnsClientNrptRule -Namespace '{suffix}','{apex}' -NameServers '{nameserver}' -Comment 'LocalDNS' -DisplayName 'LocalDNS: {zone}'\n"
                ));
                changed = true;
            }

            if !changed {
                return Response::ok(false);
            }
            script.push_str("Clear-DnsClientCache\n");
            run_powershell(&script)
        }

        pub fn unregister_all() -> Response {
            let owned = owned_rules();
            if owned.is_empty() {
                return Response::ok(false);
            }
            let mut script = String::from("$ErrorActionPreference = 'Stop'\n");
            for rule in &owned {
                if valid_guid_key(&rule.key) {
                    script.push_str(&format!(
                        "Remove-DnsClientNrptRule -Name '{}' -Force\n",
                        rule.key
                    ));
                }
            }
            script.push_str("Clear-DnsClientCache\n");
            run_powershell(&script)
        }

        fn run_powershell(script: &str) -> Response {
            let output = Command::new("powershell.exe")
                .args([
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-Command",
                    script,
                ])
                .output();
            match output {
                Ok(out) if out.status.success() => Response::ok(true),
                Ok(out) => Response::fail(format!(
                    "PowerShell failed: {}",
                    String::from_utf8_lossy(&out.stderr).trim()
                )),
                Err(error) => Response::fail(format!("PowerShell launch failed: {error}")),
            }
        }
    }
}
