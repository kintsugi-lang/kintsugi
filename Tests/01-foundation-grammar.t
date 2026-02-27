use Test;
use Kintsugi::Foundation::Grammar;

my @test-files = 't/test-files'.IO.dir(test => / 'ktgf' $$ /).sort;
plan @test-files.elems;
for @test-files {
    subtest .basename => {
        Kintsugi::Foundation::Grammar.parsefile($_).&isnt(Nil);
    }
}
