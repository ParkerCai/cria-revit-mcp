using System.Linq;
using RvtMcp.Plugin;
using RvtMcp.Server;
using Xunit;

namespace RvtMcp.Tests
{
    public class SafetyProfileTests
    {
        private static readonly string[] DestructiveTools =
        {
            "revit_delete_element",
            "revit_unload_family",
            "revit_purge_unused",
            "revit_wipe_empty_tags",
            "revit_remove_filter_from_view",
            "revit_unload_link",
            "revit_remove_parameter_binding",
            "revit_delete_view_template",
            "revit_delete_saved_selection",
            "revit_workflow_view_cleanup"
        };

        [Fact]
        public void Safe_authoring_is_default_and_excludes_arbitrary_code_and_delete()
        {
            var config = new RvtMcpConfig();
            var tools = ToolsetFilter.Resolve(config);

            Assert.Equal(RvtMcpConfig.ProfileSafeAuthoring, config.ProfileOrDefault);
            Assert.Contains("create", tools);
            Assert.Contains("modify", tools);
            Assert.Contains("batch", tools);
            Assert.DoesNotContain("delete", tools);
            Assert.DoesNotContain("toolbaker", tools);
        }

        [Fact]
        public void Developer_profile_adds_toolbaker_but_not_delete()
        {
            var config = new RvtMcpConfig { Profile = RvtMcpConfig.ProfileDeveloper };
            var tools = ToolsetFilter.Resolve(config);

            Assert.Contains("toolbaker", tools);
            Assert.DoesNotContain("delete", tools);
        }

        [Theory]
        [InlineData(RvtMcpConfig.ProfileSafeAuthoring)]
        [InlineData(RvtMcpConfig.ProfileDeveloper)]
        public void Profiles_without_delete_hide_every_destructive_tool(string profile)
        {
            var config = new RvtMcpConfig { Profile = profile };
            var active = RvtMcp.Server.Program.ResolveRegisteredToolNames(ToolsetFilter.Resolve(config), config);

            Assert.All(DestructiveTools, name => Assert.DoesNotContain(name, active));
        }

        [Fact]
        public void Explicit_all_toolsets_exposes_the_destructive_surface()
        {
            var config = new RvtMcpConfig { Toolsets = new System.Collections.Generic.List<string> { "all" } };
            var active = RvtMcp.Server.Program.ResolveRegisteredToolNames(ToolsetFilter.Resolve(config), config);

            Assert.All(DestructiveTools, name => Assert.Contains(name, active));
        }

        [Fact]
        public void Every_delete_tool_advertises_destructive_metadata()
        {
            var methods = typeof(RvtMcp.Server.DeleteTools).GetMethods(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static);
            var attributes = methods
                .Select(method => method.GetCustomAttributes(typeof(ModelContextProtocol.Server.McpServerToolAttribute), false)
                    .Cast<ModelContextProtocol.Server.McpServerToolAttribute>()
                    .SingleOrDefault())
                .Where(attribute => attribute != null)
                .ToArray();

            Assert.Equal(DestructiveTools.Length, attributes.Length);
            Assert.All(attributes, attribute => Assert.True(attribute.Destructive));
        }

        [Fact]
        public void Read_only_profile_strips_every_write_capable_toolset()
        {
            var config = new RvtMcpConfig
            {
                Profile = RvtMcpConfig.ProfileReadOnly,
                Toolsets = ToolsetFilter.KnownToolsets.ToList()
            };
            var tools = ToolsetFilter.Resolve(config);

            Assert.All(ToolsetFilter.WriteCapable, name => Assert.DoesNotContain(name, tools));
            Assert.DoesNotContain("batch", tools);
            Assert.DoesNotContain("view", tools);
            Assert.Contains("query", tools);
            Assert.Contains("geometry", tools);
        }

        [Theory]
        [InlineData("read-only")]
        [InlineData("safe-authoring")]
        [InlineData("developer")]
        public void Known_profiles_are_accepted(string profile)
        {
            Assert.True(RvtMcpConfig.IsKnownProfile(profile));
            Assert.Equal(profile, RvtMcpConfig.NormalizeProfile(profile));
        }

        [Fact]
        public void Unknown_profile_is_rejected()
        {
            Assert.False(RvtMcpConfig.IsKnownProfile("unsafe"));
        }
    }
}
