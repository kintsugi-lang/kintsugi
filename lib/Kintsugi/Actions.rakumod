use Kintsugi::AST;

class Kintsugi::Actions {
    method datatype:sym<get-word>($/) {
        $/.make(AST::GetWord.new(name => ~$/.substr(1)));
    }

    method datatype:sym<set-word>($/) {
        $/.make(AST::SetWord.new(name => ~$/.chop));
    }
    
    method datatype:sym<lit-word>($/) {
        $/.make(AST::LitWord.new(name => ~$/.substr(1)));
    }

    method datatype:sym<integer>($/) {
        $/.make(AST::Integer.new(value => +$/));
    }

    method datatype:sym<float>($/) {
        $/.make(AST::Float.new(value => +$/));
    }

    method datatype:sym<logic>($/) {
        $/.make(AST::Logic.new(value => $/ ~~ 'true' | 'on' | 'yes'));
    }

    method datatype:sym<string>($/) {
        $/.make(AST::String.new(value => ~$/));
    }

    method datatype:sym<none>($/) {
        $/.make(AST::None.new);
    }

    method datatype:sym<file>($/) {
        $/.make(AST::File.new(name => ~$/.substr(1)));
    }

    method datatype:sym<block>($/) {
        my $block = AST::Block.new;
        $block.items.push(.made) for $<block-items><datatype>;
        $/.make($block);
    }

    method datatype:sym<function>($/) {
        $/.make(AST::Function.new(params => $<block>[0], body => $<block>[1]));
    }
    
    method datatype:sym<operator>($/) {
        $/.make(AST::Word.new(params => $<block>[0], body => $<block>[1]));
    }
    
    method TOP($/) {
        my $top = AST::TOP.new;
        $top.items.push(.made) for $<block-items><datatype>;
        $/.make($top);
    }
}
