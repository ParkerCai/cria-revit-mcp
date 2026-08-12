using System.Linq;
using RvtMcp.Plugin;
using RvtMcp.Server;
using Xunit;

namespace RvtMcp.Tests
{
    public class SafetyProfileTests
    {
        [Fact]
        public void Safe_authoring_is_default_and_excludes_arbitrary_code_and_delete()
        {
            var config = new RvtMcpConfig();
            var tools = ToolsetFilter.Resolve(config);

            Assert.Equal(RvtMcpConfig.ProfileSafeAuthoring, config.ProfileOrDefault);
            Assert.Contains("create", tools);
            Assert.Contains("modify", tools);
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
