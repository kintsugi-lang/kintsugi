use Kintsugi::AST;
use Kintsugi::Dictionary;
use X::Kintsugi::Errors;

class Kintsugi::Evaluator {
    has @.scopes;
    has %.dictionary;
    has Str $.source;

    submethod TWEAK() {
        @!scopes.push(%());
        %!dictionary = |%!dictionary, |%Kintsugi::Dictionary::Core::words;
    }

    method loc($node) {
        return "" unless $!source && $node.?from.defined;
        my $line = $!source.substr(0, $node.from).split("\n").elems;
        " at line $line";
    }

    # --- Scope ---

    method push-scope() { @!scopes.push({}) }
    method pop-scope()  { @!scopes.pop }

    method set(Str $name, $value) {
        @!scopes[*-1]{$name} = $value;
    }

    method get(Str $name, $node?) {
        for @!scopes.reverse -> %scope {
            return %scope{$name} if %scope{$name}:exists;
        }
        return %!dictionary{$name} if %!dictionary{$name}:exists;
        die X::Kintsugi::UndefinedWord.new(message => "Undefined word: {$name}{self.loc($node)}");
    }

    # --- Walk ---

    method run(AST::TOP $top) {
        self.run-items($top.items);
    }

    method run-items(@items) {
        my $result;
        my $pos = 0;
        while $pos < @items.elems {
            ($result, $pos) = self.step(@items, $pos);
        }
        $result;
    }

    # Evaluate one expression starting at $pos.
    # Returns (value, next-position).
    method step(@items, Int $pos is copy --> List) {
        my $node = @items[$pos];
        my $val;

        given $node {
            when AST::SetWord {
                my $name = .value;
                $pos++;
                ($val, $pos) = self.step(@items, $pos);
                self.set($name, $val);
            }

            when AST::Word {
                my $entry = self.get(.value, $node);
                if $entry ~~ Associative && ($entry<arity>:exists) {
                    my $word-name = .value;
                    $pos++;
                    my $remaining = @items.elems - $pos;
                    if $remaining < $entry<arity> {
                        die X::Kintsugi::ArityError.new(message => "{$word-name}: Expected {$entry<arity>} arguments, got {$remaining}{self.loc($node)}");
                    }
                    my @args;
                    for ^$entry<arity> {
                        my $arg;
                        ($arg, $pos) = self.step(@items, $pos);
                        @args.push($arg);
                    }
                    if $entry<native>:exists {
                        $val = $entry<native>(|@args);
                    } else {
                        self.push-scope();
                        for $entry<params>.kv -> $i, $name {
                            self.set($name, @args[$i]);
                        }
                        $val = self.run-items($entry<body>.items);
                        self.pop-scope();
                    }
                } else {
                    $val = $entry;
                    $pos++;
                }
            }

            when AST::GetWord {
                # returns the word itself, no evaluation
                $val = .value;
                $pos++;
            }

            when AST::LitWord {
                # returns the word name as a value
                $val = .value;
                $pos++;
            }

            when AST::Integer { $val = .value; $pos++ }
            when AST::Float   { $val = .value; $pos++ }
            when AST::Logic   { $val = .value; $pos++ }
            when AST::String  { $val = .value; $pos++ }
            when AST::None    { $val = Nil;    $pos++ }
            when AST::Function {
                for .params.items -> $p {
                    die X::Kintsugi::TypeError.new(message => "Function parameter must be a word, got {$p.^name}{self.loc($p)}")
                        unless $p ~~ AST::Word;
                }
                my @param-nodes = .params.items;
                my @params = @param-nodes.map(*.value);
                my $seen = SetHash.new;
                for @param-nodes -> $p {
                    die X::Kintsugi::DuplicateParam.new(message => "Duplicate parameter: {$p.value}{self.loc($p)}") if $seen{$p.value};
                    $seen.set($p.value);
                }
                $val = %( arity => @params.elems, params => @params, body => .body );
                $pos++;
            }
            when AST::Block   { $val = $node;  $pos++ }
            when AST::Paren   { $val = self.run-items(.items); $pos++ }

            default { $val = $node; $pos++ }
        }

        # Infix lookahead: if next item is an operator, consume it
        while $pos < @items.elems && @items[$pos] ~~ AST::Operator {
            my $op-name = @items[$pos].value;
            $pos++;
            my $right;
            ($right, $pos) = self.step(@items, $pos);
            $val = %!dictionary{$op-name}<native>($val, $right);
        }

        ($val, $pos);
    }
}
