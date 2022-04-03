use Test;
use Kintsugi::Standard::Grammar;

my @test-files = 't/test-files'.IO.dir(test => / 'ktg' $$ /).sort;
plan @test-files.elems;
for @test-files {
    subtest .basename => {
        Kintsugi::Standard::Grammar.parsefile($_).&isnt(Nil);
    }
}
