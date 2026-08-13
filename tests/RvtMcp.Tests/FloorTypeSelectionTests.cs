using System.Collections.Generic;
using RvtMcp.Plugin;
using Xunit;

namespace RvtMcp.Tests
{
    public class FloorTypeSelectionTests
    {
        [Fact]
        public void SelectDefault_excludes_structural_foundations()
        {
            var candidates = new[]
            {
                Candidate(10, "Foundation Slab", isFloorCategory: true, isFoundationSlab: true),
                Candidate(20, "Generic Floor", isFloorCategory: true, isFoundationSlab: false)
            };

            Assert.Equal(20, FloorTypeSelection.SelectDefault(candidates, preferredTypeId: null));
        }

        [Fact]
        public void SelectDefault_ignores_foundation_preferred_type()
        {
            var candidates = new[]
            {
                Candidate(10, "Foundation Slab", isFloorCategory: false, isFoundationSlab: true),
                Candidate(20, "Generic Floor", isFloorCategory: true, isFoundationSlab: false)
            };

            Assert.Equal(20, FloorTypeSelection.SelectDefault(candidates, preferredTypeId: 10));
        }

        [Fact]
        public void SelectDefault_excludes_non_floor_categories_even_without_foundation_flag()
        {
            var candidates = new[]
            {
                Candidate(10, "Structural Type", isFloorCategory: false, isFoundationSlab: false),
                Candidate(20, "Generic Floor", isFloorCategory: true, isFoundationSlab: false)
            };

            Assert.Equal(20, FloorTypeSelection.SelectDefault(candidates, preferredTypeId: null));
        }

        [Fact]
        public void SelectDefault_honors_eligible_preferred_type()
        {
            var candidates = new[]
            {
                Candidate(20, "A Floor", isFloorCategory: true, isFoundationSlab: false),
                Candidate(30, "Z Floor", isFloorCategory: true, isFoundationSlab: false)
            };

            Assert.Equal(30, FloorTypeSelection.SelectDefault(candidates, preferredTypeId: 30));
        }

        [Fact]
        public void SelectDefault_fallback_is_stable_across_input_order()
        {
            var firstOrder = new[]
            {
                Candidate(40, "Office Floor", isFloorCategory: true, isFoundationSlab: false),
                Candidate(20, "Generic Floor", isFloorCategory: true, isFoundationSlab: false),
                Candidate(10, "Generic Floor", isFloorCategory: true, isFoundationSlab: false)
            };
            var secondOrder = new List<FloorTypeSelectionCandidate>(firstOrder);
            secondOrder.Reverse();

            Assert.Equal(10, FloorTypeSelection.SelectDefault(firstOrder, preferredTypeId: null));
            Assert.Equal(10, FloorTypeSelection.SelectDefault(secondOrder, preferredTypeId: null));
        }

        [Fact]
        public void SelectDefault_returns_null_when_only_foundations_are_available()
        {
            var candidates = new[]
            {
                Candidate(10, "Foundation A", isFloorCategory: true, isFoundationSlab: true),
                Candidate(11, "Foundation B", isFloorCategory: true, isFoundationSlab: true)
            };

            Assert.Null(FloorTypeSelection.SelectDefault(candidates, preferredTypeId: null));
        }

        [Theory]
        [InlineData(true, false, true)]
        [InlineData(true, true, false)]
        [InlineData(false, false, false)]
        public void IsEligible_applies_to_explicit_and_automatic_selection(
            bool isFloorCategory,
            bool isFoundationSlab,
            bool expected)
        {
            Assert.Equal(
                expected,
                FloorTypeSelection.IsEligible(Candidate(10, "Explicit Type", isFloorCategory, isFoundationSlab)));
        }

        private static FloorTypeSelectionCandidate Candidate(
            long id,
            string name,
            bool isFloorCategory,
            bool isFoundationSlab)
        {
            return new FloorTypeSelectionCandidate(id, name, isFloorCategory, isFoundationSlab);
        }
    }
}
