use Kintsugi::AST;

class Kintsugi::Actions {
    method datatype:sym<set-word>($/) {
        $/.make(AST::WordAssignment.new(name => ~$/.chop: 1));
    }

    method datatype:sym<integer>($/) {
        $/.make(AST::IntegerValue.new(value => +$/));
    }
    
    method TOP($/) {
        my $top = AST::TOP.new;
        $top.items.push(.made) for $<block-items><datatype>;
        $/.make($top);
    }
}
