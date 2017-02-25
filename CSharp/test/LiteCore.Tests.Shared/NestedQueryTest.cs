using FluentAssertions;
using Xunit;
using Xunit.Abstractions;

namespace LiteCore.Tests
{
    public unsafe class NestedQueryTest : QueryTestBase
    {
        protected override string JsonPath 
        {
            get {
                return "C/tests/data/nested.json";
            }
        }

        public NestedQueryTest(ITestOutputHelper output) : base(output)
        {

        }

        [Fact]
        public void TestDBQueryAnyNested()
        {
            RunTestVariants(() => {
                Compile(Json5("['ANY', 'Shape', ['.', 'shapes'], ['=', ['?', 'Shape', 'color'], 'red']]"));
                Run().Should().Equal(new[] { "0000001", "0000003" }, "because otherwise the query returned incorrect results");
            });
        }
    }
}