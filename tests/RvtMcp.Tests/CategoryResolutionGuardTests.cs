using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using RvtMcp.Plugin;
using Xunit;

namespace RvtMcp.Tests
{
    public class CategoryResolutionGuardTests
    {
        [Fact]
        public void ResolveAll_accepts_only_when_every_requested_category_resolves()
        {
            var categories = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase)
            {
                ["OST_Walls"] = new object(),
                ["Floors"] = new object()
            };

            var result = CategoryResolutionGuard.ResolveAll(
                new[] { "OST_Walls", "Floors" },
                name => categories.TryGetValue(name, out var category) ? category : null);

            Assert.Equal(new[] { "OST_Walls", "Floors" }, result.Requested);
            Assert.Equal(2, result.Resolved.Count);
            Assert.Empty(result.Unresolved);
        }

        [Fact]
        public void ResolveAll_reports_partial_resolution_instead_of_narrowing_the_filter()
        {
            var wall = new object();

            var result = CategoryResolutionGuard.ResolveAll(
                new[] { "OST_Walls", "OST_Floors", "OST_StructuralFoundation" },
                name => name == "OST_Walls" ? wall : null);

            Assert.Single(result.Resolved);
            Assert.Equal(
                new[] { "OST_Floors", "OST_StructuralFoundation" },
                result.Unresolved);
            Assert.Contains("No volume query was run", CategoryResolutionGuard.UnresolvedError(result.Unresolved));
        }

        [Fact]
        public void ResolveAll_reports_every_category_when_none_resolve()
        {
            var result = CategoryResolutionGuard.ResolveAll<object>(
                new[] { "Unknown A", "Unknown B" },
                _ => null);

            Assert.Empty(result.Resolved);
            Assert.Equal(new[] { "Unknown A", "Unknown B" }, result.Unresolved);
            var error = CategoryResolutionGuard.UnresolvedError(result.Unresolved);
            Assert.Contains("'Unknown A'", error);
            Assert.Contains("'Unknown B'", error);
            Assert.Contains("BuiltInCategory tokens such as OST_Walls", error);
        }

        [Fact]
        public void ResolveAll_preserves_locale_independent_tokens_and_deduplicates_case_insensitively()
        {
            var resolvedNames = new List<string>();

            var result = CategoryResolutionGuard.ResolveAll(
                new[] { "  OST_StructuralFoundation  ", "ost_structuralfoundation" },
                name =>
                {
                    resolvedNames.Add(name);
                    return new object();
                });

            Assert.Equal(new[] { "OST_StructuralFoundation" }, result.Requested);
            Assert.Equal(new[] { "OST_StructuralFoundation" }, resolvedNames);
            Assert.Single(result.Resolved);
            Assert.Empty(result.Unresolved);
        }

        [Fact]
        public void ParseRequestedNames_allows_an_intentionally_empty_array_as_no_filter()
        {
            var result = CategoryResolutionGuard.ParseRequestedNames(new JArray());

            Assert.Empty(result);
        }

        [Fact]
        public void ParseRequestedNames_preserves_omitted_or_null_as_no_filter()
        {
            Assert.Null(CategoryResolutionGuard.ParseRequestedNames(null));
            Assert.Null(CategoryResolutionGuard.ParseRequestedNames(JValue.CreateNull()));
        }

        [Fact]
        public void ParseRequestedNames_rejects_non_array_input()
        {
            var exception = Assert.Throws<ArgumentException>(() =>
                CategoryResolutionGuard.ParseRequestedNames(new JObject { ["name"] = "OST_Walls" }));

            Assert.Equal("categories must be a JSON array when supplied.", exception.Message);
        }

        [Theory]
        [InlineData("")]
        [InlineData("   ")]
        public void ParseRequestedNames_rejects_blank_entries(string blank)
        {
            var exception = Assert.Throws<ArgumentException>(() =>
                CategoryResolutionGuard.ParseRequestedNames(new JArray("OST_Walls", blank)));

            Assert.Equal("categories[1] must be a non-empty string.", exception.Message);
        }

        [Fact]
        public void ParseRequestedNames_rejects_non_string_entries()
        {
            var exception = Assert.Throws<ArgumentException>(() =>
                CategoryResolutionGuard.ParseRequestedNames(new JArray("OST_Walls", 42)));

            Assert.Equal("categories[1] must be a non-empty string.", exception.Message);
        }

        [Fact]
        public void ResolveAll_defensively_rejects_blank_names()
        {
            var exception = Assert.Throws<ArgumentException>(() =>
                CategoryResolutionGuard.ResolveAll<object>(
                    new[] { "OST_Walls", "" },
                    _ => new object()));

            Assert.Equal("categories[1] must be a non-empty string.", exception.Message);
        }
    }
}
