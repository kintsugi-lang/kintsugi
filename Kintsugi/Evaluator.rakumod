use Kintsugi::AST;

class Kintsugi::Evaluator {
    has @.scopes;
    has %.builtins;

    submethod TWEAK() {
        @!scopes.push(%());
        self.register-builtins();
    }

    # --- Scope ---

    method push-scope() { @!scopes.push({}) }
    method pop-scope()  { @!scopes.pop }

    method set(Str $name, $value) {
        @!scopes[*-1]{$name} = $value;
    }

    method get(Str $name) {
        for @!scopes.reverse -> %scope {
            return %scope{$name} if %scope{$name}:exists;
        }
        return %!builtins{$name} if %!builtins{$name}:exists;
        die "Undefined word: $name";
    }

    # --- Builtins ---

    method register-builtins() {
        %!builtins<print> = { arity => 1, fn => -> $v { say $v; $v } };
    }

    method op(Str $name, $left, $right) {
        given $name {
            when '+' { $left + $right }
            when '-' { $left - $right }
            when '*' { $left * $right }
            when '/' { $left / $right }
            when '>' { $left > $right }
            when '<' { $left < $right }
            when '=' { $left == $right }
            default  { die "Unknown operator: $name" }
        }
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
                my $entry = self.get(.value);
                if $entry ~~ Associative && ($entry<arity>:exists) {
                    # it's a builtin function — consume arity args
                    $pos++;
                    my @args;
                    for ^$entry<arity> {
                        my $arg;
                        ($arg, $pos) = self.step(@items, $pos);
                        @args.push($arg);
                    }
                    $val = $entry<fn>(|@args);
                } else {
                    # it's a plain value
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
            $val = self.op($op-name, $val, $right);
        }

        ($val, $pos);
    }
}
