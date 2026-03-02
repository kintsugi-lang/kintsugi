use Kintsugi::AST;

class Kintsugi::Actions {

    method !span($/) { %(from => $/.from, to => $/.to) }

    # --- Rule-level actions ---

    method block($/) {
        my $block = AST::Block.new(|self!span($/));
        for $<block-items><datatype> {
            $block.items.push(.made) if .made.defined;
        }
        $/.make($block);
    }

    method paren($/) {
        my $paren = AST::Paren.new(|self!span($/));
        for $<block-items><datatype> {
            $paren.items.push(.made) if .made.defined;
        }
        $/.make($paren);
    }

    method header($/) {
        $/.make(AST::Header.new(
            tier  => (~$/).split('[')[0].trim,
            block => $<block>.made,
            |self!span($/),
        ));
    }

    method TOP($/) {
        my @items;
        for $<block-items><datatype> {
            @items.push(.made) if .made.defined;
        }
        $/.make(AST::TOP.new(header => $<header>.made, items => @items, |self!span($/)));
    }

    # --- Words ---

    method datatype:sym<word>($/) {
        $/.make(AST::Word.new(value => ~$/, |self!span($/)));
    }

    method datatype:sym<set-word>($/) {
        $/.make(AST::SetWord.new(value => ~$/.chop, |self!span($/)));
    }

    method datatype:sym<get-word>($/) {
        $/.make(AST::GetWord.new(value => ~$/.substr(1), |self!span($/)));
    }

    method datatype:sym<lit-word>($/) {
        $/.make(AST::LitWord.new(value => ~$/.substr(1), |self!span($/)));
    }

    # --- Scalars ---

    method datatype:sym<integer>($/) {
        $/.make(AST::Integer.new(value => +$/, |self!span($/)));
    }

    method datatype:sym<float>($/) {
        $/.make(AST::Float.new(value => +$/, |self!span($/)));
    }

    method datatype:sym<logic>($/) {
        my $v = ~$/;
        $/.make(AST::Logic.new(value => $v eq 'true' || $v eq 'on' || $v eq 'yes', |self!span($/)));
    }

    method datatype:sym<none>($/) {
        $/.make(AST::None.new(|self!span($/)));
    }

    method datatype:sym<char>($/) {
        $/.make(AST::Char.new(value => (~$/).substr(2, 1), |self!span($/)));
    }

    method datatype:sym<pair>($/) {
        my ($x, $y) = (~$/).split('x');
        $/.make(AST::Pair.new(x => +$x, y => +$y, |self!span($/)));
    }

    method datatype:sym<money>($/) {
        $/.make(AST::Money.new(value => +(~$/).substr(1), |self!span($/)));
    }

    method datatype:sym<date>($/) {
        $/.make(AST::Date.new(value => ~$/, |self!span($/)));
    }

    method datatype:sym<time>($/) {
        $/.make(AST::Time.new(value => ~$/, |self!span($/)));
    }

    method datatype:sym<tuple>($/) {
        $/.make(AST::Tuple.new(value => ~$/, |self!span($/)));
    }

    # --- Text ---

    method datatype:sym<string>($/) {
        $/.make(AST::String.new(value => ~$<string><string-contents>, |self!span($/)));
    }

    method datatype:sym<binary>($/) {
        my $hex = (~$/).substr(2, *-1);
        $/.make(AST::Binary.new(value => $hex, |self!span($/)));
    }

    # --- Resources ---

    method datatype:sym<file>($/) {
        $/.make(AST::File.new(value => (~$/).substr(1), |self!span($/)));
    }

    method datatype:sym<url>($/) {
        $/.make(AST::URL.new(value => ~$/, |self!span($/)));
    }

    method datatype:sym<email>($/) {
        $/.make(AST::Email.new(value => ~$/, |self!span($/)));
    }

    # --- Composites ---

    method datatype:sym<block>($/) {
        $/.make($<block>.made);
    }

    method datatype:sym<paren>($/) {
        $/.make($<paren>.made);
    }

    method datatype:sym<function>($/) {
        $/.make(AST::Function.new(
            params => $<function><block>[0].made,
            body   => $<function><block>[1].made,
            |self!span($/),
        ));
    }

    method datatype:sym<operator>($/) {
        $/.make(AST::Operator.new(value => ~$/, |self!span($/)));
    }

    method datatype:sym<directive>($/) {
        $/.make(AST::Directive.new(value => (~$/).substr(1), |self!span($/)));
    }

    # Comments produce no AST node
    method datatype:sym<comment>($/) { }
}
