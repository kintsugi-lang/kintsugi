use Kintsugi::AST;

class Kintsugi::Evaluator {
    has %.symbol-table;

    method eval(ASTNode $top) {
        dd $top;

        self.eval-node($_) for $top.statements;
        
        dd %!symbol-table;
    }

    multi method eval-node(AST::WordAssignment $node) {
        return unless $node.value ~~ ASTNode;
        %!symbol-table{$node.word-name} = $node.value.value
    }
}
