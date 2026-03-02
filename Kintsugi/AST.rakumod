role Span { has Int $.from; has Int $.to; }
role Value[::T] { has T $.value; }

class AST::Block does Span {
    has @.items = [];
}

class AST::TOP is AST::Block {
    has $.header;
}

class AST::Header does Span {
    has Str $.tier;
    has AST::Block $.block;
}

# --- Scalars ---

class AST::None does Span {}
class AST::Integer does Span does Value[Int] {}
class AST::Float does Span does Value[Rat] {}
class AST::Logic does Span does Value[Bool] {}
class AST::Char does Span does Value[Str] {}
class AST::Pair does Span {
    has $.x;
    has $.y;
}
class AST::Money does Span does Value[Rat] {}
class AST::Tuple does Span does Value[Str] {}
class AST::Date does Span does Value[Str] {}
class AST::Time does Span does Value[Str] {}

# --- Text ---

class AST::String does Span does Value[Str] {}
class AST::Binary does Span does Value[Str] {}

# --- Resources ---

class AST::File does Span does Value[Str] {}
class AST::URL does Span does Value[Str] {}
class AST::Email does Span does Value[Str] {}

# --- Composites ---

class AST::Paren does Span {
    has @.items = [];
}

class AST::Function does Span {
    has $.params;
    has $.body;
}

# --- Words ---

class AST::Word does Span does Value[Str] {}
class AST::SetWord does Span does Value[Str] {}
class AST::GetWord does Span does Value[Str] {}
class AST::LitWord does Span does Value[Str] {}
class AST::Operator does Span does Value[Str] {}

# --- Directives ---

class AST::Directive does Span does Value[Str] {}
