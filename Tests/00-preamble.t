use Test;
use lib '../lib';
use Kintsugi::Foundation::Grammar;
use Kintsugi::Actions;
use Kintsugi::AST;

plan 1;

subtest 'preamble' => {
    True.&is(True);
}
