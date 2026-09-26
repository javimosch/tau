/// tau package version. Single source of truth so CLI, JSON output and ACP
/// `agentInfo` all report the same value.
pub const version = "0.4.0";

/// Canonical troubleshooting doc URL. Embedded in every `{"err":...}` envelope
/// so agents and humans can jump straight from an error to the fix list.
pub const troubleshooting_doc_url = "https://github.com/javimosch/tau/blob/master/docs/troubleshooting.md";

test "version is a non-empty dotted triple" {
    try @import("std").testing.expect(version.len > 0);
    try @import("std").testing.expectEqualStrings("0.4.0", version);
}
