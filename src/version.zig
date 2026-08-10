/// tau package version. Single source of truth so CLI, JSON output and ACP
/// `agentInfo` all report the same value.
pub const version = "0.4.0";

test "version is a non-empty dotted triple" {
    try @import("std").testing.expect(version.len > 0);
    try @import("std").testing.expectEqualStrings("0.4.0", version);
}
