role Value[::T] { has T $.value; }

class AST::Block {
    has @.items = [];
}

class AST::TOP is AST::Block {
    has $.header;
}

class AST::Header {
    has Str $.tier;
    has AST::Block $.block;
}

# --- Scalars ---

class AST::None {}
class AST::Integer does Value[Int] {}
class AST::Float does Value[Rat] {}
class AST::Logic does Value[Bool] {}
class AST::Char does Value[Str] {}
class AST::Pair {
    has $.x;
    has $.y;
}
class AST::Money does Value[Rat] {}
class AST::Tuple does Value[Str] {}
class AST::Date does Value[Str] {}
class AST::Time does Value[Str] {}

# --- Text ---

class AST::String does Value[Str] {}
class AST::Binary does Value[Str] {}

# --- Resources ---

class AST::File does Value[Str] {}
class AST::URL does Value[Str] {}
class AST::Email does Value[Str] {}

# --- Composites ---

class AST::Paren {
    has @.items = [];
}

class AST::Function {
    has $.params;
    has $.body;
}

# --- Words ---

class AST::Word does Value[Str] {}
class AST::SetWord does Value[Str] {}
class AST::GetWord does Value[Str] {}
class AST::LitWord does Value[Str] {}
class AST::Operator does Value[Str] {}

# --- Directives ---

class AST::Directive does Value[Str] {}
