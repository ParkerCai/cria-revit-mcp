using System;
using System.Collections.Generic;
using System.Linq;

namespace RvtMcp.Plugin
{
    internal sealed class FloorTypeSelectionCandidate
    {
        public FloorTypeSelectionCandidate(
            long id,
            string name,
            bool isFloorCategory,
            bool isFoundationSlab)
        {
            Id = id;
            Name = name ?? string.Empty;
            IsFloorCategory = isFloorCategory;
            IsFoundationSlab = isFoundationSlab;
        }

        public long Id { get; }
        public string Name { get; }
        public bool IsFloorCategory { get; }
        public bool IsFoundationSlab { get; }
    }

    internal static class FloorTypeSelection
    {
        public static bool IsEligible(FloorTypeSelectionCandidate candidate)
        {
            return candidate != null
                && candidate.IsFloorCategory
                && !candidate.IsFoundationSlab;
        }

        public static long? SelectDefault(
            IEnumerable<FloorTypeSelectionCandidate> candidates,
            long? preferredTypeId)
        {
            if (candidates == null)
                throw new ArgumentNullException(nameof(candidates));

            var eligible = candidates
                .Where(IsEligible)
                .ToList();

            if (preferredTypeId.HasValue
                && eligible.Any(candidate => candidate.Id == preferredTypeId.Value))
            {
                return preferredTypeId.Value;
            }

            var selected = eligible
                .OrderBy(candidate => candidate.Name, StringComparer.OrdinalIgnoreCase)
                .ThenBy(candidate => candidate.Name, StringComparer.Ordinal)
                .ThenBy(candidate => candidate.Id)
                .FirstOrDefault();

            return selected?.Id;
        }
    }
}
