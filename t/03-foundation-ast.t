use Test;
use lib '../lib';
use Kintsugi::Foundation::Grammar;
use Kintsugi::Actions;
use Kintsugi::AST;

plan 1;

subtest 'simple assignment' => {
    my $result = Kintsugi::Foundation::Grammar.parse(
        't/test-files/simple-assignment.ktgf'.IO.slurp,
        actions => Kintsugi::Actions
    );

    $result.made.items.elems.&is(2);
    ($result.made.items[0] ~~ AST::WordAssignment).&is(True);
    ($result.made.items[1] ~~ AST::IntegerValue).&is(True);
}
