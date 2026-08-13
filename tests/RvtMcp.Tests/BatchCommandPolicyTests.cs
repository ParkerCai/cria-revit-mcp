using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using RvtMcp.Plugin;
using RvtMcp.Server;
using Xunit;

namespace RvtMcp.Tests
{
    public class BatchCommandPolicyTests
    {
        [Fact]
        public void Safe_authoring_allows_exposed_typed_authoring_commands()
        {
            var config = new RvtMcpConfig();
            var active = RvtMcp.Server.Program.ResolveRegisteredToolNames(ToolsetFilter.Resolve(config), config);

            var violation = BatchCommandPolicy.Validate(Commands("create_level", "create_grid"), active);

            Assert.Null(violation);
        }

        [Theory]
        [InlineData("delete_element")]
        [InlineData("send_code_to_revit")]
        [InlineData("run_baked_tool")]
        [InlineData("batch_execute")]
        public void Dangerous_escape_hatches_are_never_allowed_inside_batch(string command)
        {
            var config = new RvtMcpConfig
            {
                Toolsets = new List<string> { "all" },
                EnableToolbaker = true
            };
            var active = RvtMcp.Server.Program.ResolveRegisteredToolNames(ToolsetFilter.Resolve(config), config);

            var violation = BatchCommandPolicy.Validate(Commands(command), active);

            Assert.NotNull(violation);
            Assert.Equal("batch_command_forbidden", violation.Code);
            Assert.Equal(command, violation.Command);
        }

        [Fact]
        public void Command_hidden_by_custom_toolsets_is_rejected()
        {
            var config = new RvtMcpConfig
            {
                Toolsets = new List<string> { "query", "batch" }
            };
            var active = RvtMcp.Server.Program.ResolveRegisteredToolNames(ToolsetFilter.Resolve(config), config);

            var violation = BatchCommandPolicy.Validate(Commands("create_level"), active);

            Assert.NotNull(violation);
            Assert.Equal("batch_command_not_exposed", violation.Code);
        }

        [Theory]
        [InlineData("export_family_to_path")]
        [InlineData("select_elements")]
        [InlineData("write_kei_database")]
        [InlineData("activate_view")]
        public void Exposed_command_with_external_or_ui_effects_is_not_atomic(string command)
        {
            var config = new RvtMcpConfig
            {
                Toolsets = new List<string> { "all" },
                EnableToolbaker = true
            };
            var active = RvtMcp.Server.Program.ResolveRegisteredToolNames(ToolsetFilter.Resolve(config), config);

            var violation = BatchCommandPolicy.Validate(Commands(command), active);

            Assert.NotNull(violation);
            Assert.Equal("batch_command_not_atomic", violation.Code);
            Assert.Equal(command, violation.Command);
        }

        [Theory]
        [InlineData("create_level")]
        [InlineData("create_surface_based_element")]
        [InlineData("set_element_parameter_values")]
        [InlineData("create_sheet")]
        [InlineData("place_schedule_on_sheet")]
        public void Audited_transaction_only_commands_are_allowlisted(string command)
        {
            Assert.True(AtomicBatchCommandCatalog.IsAllowed(command));
        }

        [Fact]
        public void Read_only_profile_does_not_register_batch_tool()
        {
            var config = new RvtMcpConfig { Profile = RvtMcpConfig.ProfileReadOnly };
            var active = RvtMcp.Server.Program.ResolveRegisteredToolNames(ToolsetFilter.Resolve(config), config);

            Assert.DoesNotContain("revit_batch_execute", active);
            Assert.DoesNotContain("revit_create_view", active);
            Assert.DoesNotContain("revit_set_view_crop", active);
            Assert.DoesNotContain("revit_set_view_scale", active);
            Assert.DoesNotContain("revit_place_view_on_sheet", active);
            Assert.DoesNotContain("revit_set_project_info", active);
            Assert.DoesNotContain("revit_purge_unused", active);
        }

        private static JArray Commands(params string[] names)
        {
            var commands = new JArray();
            foreach (var name in names)
            {
                commands.Add(new JObject
                {
                    ["command"] = name,
                    ["params"] = new JObject()
                });
            }
            return commands;
        }
    }
}
