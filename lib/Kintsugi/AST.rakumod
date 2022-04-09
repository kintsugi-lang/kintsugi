class ASTNode {}

role Value[::T] { has T $.value; }

class AST::Block is ASTNode {
    has ASTNode @.items = [];
}

class AST::TOP is AST::Block {}

class AST::None is ASTNode does Value[Nil] {}
class AST::Integer is ASTNode does Value[Int] {}
class AST::Float is ASTNode does Value[Rat] {}
class AST::Logic is ASTNode does Value[Bool] {}
class AST::String is ASTNode does Value[Str] {}

class AST::File is ASTNode {
    has Str $.name;
    has IO $.value is rw;
}

class AST::Function is ASTNode {
    has @.params = [];
    has ASTNode @.body = [];
}


class AST::Word is ASTNode does Value[ASTNode] {
    has Str $.name;
}

class AST::SetWord is AST::Word does Value[Any] {}
class AST::GetWord is AST::Word does Value[Any] {}
class AST::LitWord is AST::Word does Value[Str] {}
class AST::Operator is AST::Word does Value[AST::Function] {}
