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

    my @expected = [
        AST::SetWord,
        AST::Integer,
        AST::SetWord,
        AST::Float,
        AST::SetWord,
        AST::Logic,
        AST::SetWord,
        AST::String,
        AST::SetWord,
        AST::None,
        AST::SetWord,
        AST::File,
        AST::SetWord,
        AST::Block,
        AST::SetWord,
        AST::Function,
        AST::SetWord,
        AST::Function,
        AST::SetWord,
        AST::GetWord,
        AST::SetWord,
        AST::LitWord,
    ];

    for $result.made.items.kv -> $index, $node {
        my $result = $node ~~ @expected[$index];
        say $node unless $result;
        $result.&is(True);
    }
}
