using System.Collections.Generic;
using System.Text;
using ModelContextProtocol.Server;
using RvtMcp.Plugin;
using Xunit;

namespace RvtMcp.Tests
{
    public class ServerMetadataTests
    {
        [Fact]
        public void Server_identifies_as_cria()
        {
            var options = new McpServerOptions();

            RvtMcp.Server.Program.ConfigureMcpServerOptions(options);

            Assert.Equal("cria-revit-mcp", options.ServerInfo?.Name);
            Assert.Equal("Cria Revit MCP", options.ServerInfo?.Title);
            Assert.Equal("0.1.0", options.ServerInfo?.Version);
            Assert.Contains("stateless", options.ServerInfo?.Description);
            Assert.Equal("https://github.com/ParkerCai/cria-revit-mcp", options.ServerInfo?.WebsiteUrl);
            Assert.StartsWith("cria-revit-mcp", options.ServerInstructions);
        }

        [Fact]
        public void Default_safe_authoring_instructions_only_name_available_tool_examples()
        {
            var options = new McpServerOptions();

            RvtMcp.Server.Program.ConfigureMcpServerOptions(options);

            Assert.Contains("create_level", options.ServerInstructions);
            Assert.Contains("batch_execute", options.ServerInstructions);
            Assert.DoesNotContain("delete_element", options.ServerInstructions);
            Assert.DoesNotContain("send_code_to_revit", options.ServerInstructions);
            Assert.DoesNotContain("list_baked_tools", options.ServerInstructions);
        }

        [Fact]
        public void Developer_instructions_add_toolbaker_but_not_delete()
        {
            var config = new RvtMcpConfig { Profile = RvtMcpConfig.ProfileDeveloper };
            var options = Configure(config);

            Assert.Contains("send_code_to_revit", options.ServerInstructions);
            Assert.Contains("list_baked_tools", options.ServerInstructions);
            Assert.DoesNotContain("delete_element", options.ServerInstructions);
        }

        [Fact]
        public void Read_only_instructions_remove_batch_and_authoring_examples()
        {
            var config = new RvtMcpConfig { Profile = RvtMcpConfig.ProfileReadOnly };
            var options = Configure(config);

            Assert.Contains("get_current_view_info", options.ServerInstructions);
            Assert.DoesNotContain("batch_execute", options.ServerInstructions);
            Assert.DoesNotContain("create_level", options.ServerInstructions);
            Assert.DoesNotContain("create_view", options.ServerInstructions);
            Assert.DoesNotContain("capture_view_image", options.ServerInstructions);
            Assert.DoesNotContain("set_element_parameter_values", options.ServerInstructions);
        }

        [Fact]
        public void Explicit_all_toolsets_advertise_delete_and_toolbaker()
        {
            var config = new RvtMcpConfig
            {
                Toolsets = new List<string> { "all" }
            };
            var options = Configure(config);

            Assert.Contains("delete_element", options.ServerInstructions);
            Assert.Contains("send_code_to_revit", options.ServerInstructions);
            var instructionBytes = Encoding.UTF8.GetByteCount(options.ServerInstructions);
            Assert.True(instructionBytes <= 2048, $"Instruction index is {instructionBytes} UTF-8 bytes.");
        }

        [Fact]
        public void Explicit_all_with_adaptive_bake_stays_within_instruction_limit()
        {
            var config = new RvtMcpConfig
            {
                Toolsets = new List<string> { "all" },
                EnableAdaptiveBake = true
            };
            var options = Configure(config);

            Assert.True(
                Encoding.UTF8.GetByteCount(options.ServerInstructions) <= 2048,
                "Instruction index must remain within 2048 UTF-8 bytes.");
        }

        [Fact]
        public void Custom_query_toolset_does_not_advertise_meta_or_authoring_tools()
        {
            var config = new RvtMcpConfig
            {
                Toolsets = new List<string> { "query" }
            };
            var options = Configure(config);

            Assert.Contains("get_current_view_info", options.ServerInstructions);
            Assert.DoesNotContain("list_available_targets", options.ServerInstructions);
            Assert.DoesNotContain("create_level", options.ServerInstructions);
            Assert.DoesNotContain("batch_execute", options.ServerInstructions);
        }

        private static McpServerOptions Configure(RvtMcpConfig config)
        {
            var options = new McpServerOptions();
            RvtMcp.Server.Program.ConfigureMcpServerOptions(
                options,
                RvtMcp.Server.ToolsetFilter.Resolve(config),
                config);
            return options;
        }
    }
}
