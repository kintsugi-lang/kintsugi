class ASTNode {}

role Named { has Str $.name; }
role Value[::T] { has T $.value is rw; }

class AST::Block is ASTNode {
    has ASTNode @.items = [];
}

class AST::TOP is AST::Block {}

class AST::None is ASTNode {
    has $.value = Nil;
}
class AST::Integer is ASTNode does Value[Int] {}
class AST::Float is ASTNode does Value[Rat] {}
class AST::Logic is ASTNode does Value[Bool] {}
class AST::String is ASTNode does Value[Str] {}

class AST::File is ASTNode does Named does Value[IO] {}

class AST::Function is ASTNode {
    has @.params = [];
    has ASTNode @.body = [];
}


class AST::Word is ASTNode does Named does Value[ASTNode] {}

class AST::SetWord is AST::Word {}
class AST::GetWord is AST::Word {}
class AST::LitWord is AST::Word {}
class AST::Operator is AST::Word does Value[AST::Function] {}
