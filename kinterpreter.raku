use lib '.';
use Kintsugi::Grammar::Core;
use Kintsugi::Grammar::Systems;
use Kintsugi::Grammar::Full;
use Kintsugi::Actions;

# use trace;

role X::Kintsugi {
    has Str $.message;

    method gist {
        "{self.^name} — {$.message}"
    }
}

class X::Kintsugi::StartupError is Exception does X::Kintsugi {}
class X::Kintsugi::UnknownDialectError is Exception does X::Kintsugi {}
class X::Kintsugi::ParseError is Exception does X::Kintsugi {}

sub MAIN(IO(Str) $file where *.f) {
    say "=== Kintsugi Interpreter v0.0.1 ===";

    say "Entry point: {$file.basename}";
    my $grammar = do given $file.words.first {
        when / 'Kintsugi/Core' / { Kintsugi::Grammar::Core }
        when / 'Kintsugi/Systems' / { Kintsugi::Grammar::Systems }
        when / 'Kintsugi' '/Full'? / { Kintsugi::Grammar::Full }
        default {
            die X::Kintsugi::UnknownDialectError.new(message => "Did not see a valid dialect in the header.");
        }
    }
    
    my $parsed-file = $grammar.parse($file.slurp, actions => Kintsugi::Actions);
    die X::Kintsugi::ParseError.new(message => "Could not parse file.") if not so $parsed-file;
    say $parsed-file;

    CATCH {
        when X::Kintsugi {
            .gist.say;
            exit;
        } 
    }
}
