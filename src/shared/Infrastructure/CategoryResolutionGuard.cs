using System;
using System.Collections.Generic;
using System.Linq;
using Newtonsoft.Json.Linq;

namespace RvtMcp.Plugin
{
    internal sealed class CategoryResolution<T> where T : class
    {
        public CategoryResolution(
            IReadOnlyList<string> requested,
            IReadOnlyList<T> resolved,
            IReadOnlyList<string> unresolved)
        {
            Requested = requested;
            Resolved = resolved;
            Unresolved = unresolved;
        }

        public IReadOnlyList<string> Requested { get; }
        public IReadOnlyList<T> Resolved { get; }
        public IReadOnlyList<string> Unresolved { get; }
    }

    internal static class CategoryResolutionGuard
    {
        public static IReadOnlyList<string> ParseRequestedNames(JToken categoriesToken)
        {
            if (categoriesToken == null || categoriesToken.Type == JTokenType.Null)
                return null;
            if (categoriesToken.Type != JTokenType.Array)
                throw new ArgumentException("categories must be a JSON array when supplied.");

            var names = new List<string>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var array = (JArray)categoriesToken;
            for (var index = 0; index < array.Count; index++)
            {
                var token = array[index];
                if (token == null || token.Type != JTokenType.String)
                    throw new ArgumentException($"categories[{index}] must be a non-empty string.");

                var name = token.Value<string>()?.Trim();
                if (string.IsNullOrWhiteSpace(name))
                    throw new ArgumentException($"categories[{index}] must be a non-empty string.");
                if (seen.Add(name))
                    names.Add(name);
            }

            return names;
        }

        public static CategoryResolution<T> ResolveAll<T>(
            IEnumerable<string> categoryNames,
            Func<string, T> resolver) where T : class
        {
            if (categoryNames == null)
                throw new ArgumentNullException(nameof(categoryNames));
            if (resolver == null)
                throw new ArgumentNullException(nameof(resolver));

            var requested = new List<string>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var index = 0;
            foreach (var rawName in categoryNames)
            {
                var name = rawName?.Trim();
                if (string.IsNullOrWhiteSpace(name))
                    throw new ArgumentException($"categories[{index}] must be a non-empty string.");
                if (seen.Add(name))
                    requested.Add(name);
                index++;
            }
            var resolved = new List<T>();
            var unresolved = new List<string>();

            foreach (var name in requested)
            {
                var value = resolver(name);
                if (value == null)
                    unresolved.Add(name);
                else
                    resolved.Add(value);
            }

            return new CategoryResolution<T>(requested, resolved, unresolved);
        }

        public static string UnresolvedError(IEnumerable<string> unresolvedNames)
        {
            if (unresolvedNames == null)
                throw new ArgumentNullException(nameof(unresolvedNames));

            var names = unresolvedNames
                .Where(name => !string.IsNullOrWhiteSpace(name))
                .Select(name => "'" + name.Replace("'", "''") + "'")
                .ToArray();

            return "Could not resolve every requested category. Unresolved: "
                + string.Join(", ", names)
                + ". No volume query was run. Use category display names or "
                + "BuiltInCategory tokens such as OST_Walls.";
        }
    }
}
