use lib '.';
use Kintsugi::Grammar::Core;
use Kintsugi::Grammar::Systems;
use Kintsugi::Grammar::Full;
use Kintsugi::Actions;
use Kintsugi::Evaluator;
use X::Kintsugi::Errors;

sub MAIN(IO(Str) $file where *.f) {
    say "=== Kintsugi Interpreter v0.0.1 ===";

    say "Entry point: {$file.basename}";
    my $header-line = $file.lines.first(*.starts-with('Kintsugi'));
    my $grammar = do given $header-line {
        when / 'Kintsugi/Core' / { Kintsugi::Grammar::Core }
        when / 'Kintsugi/Systems' / { Kintsugi::Grammar::Systems }
        when / 'Kintsugi' '/Full'? / { Kintsugi::Grammar::Full }
        default {
            die X::Kintsugi::UnknownDialectError.new(message => "Did not see a valid dialect in the header.");
        }
    }
    
    my $parsed-file = $grammar.parse($file.slurp, actions => Kintsugi::Actions);
    die X::Kintsugi::ParseError.new(message => "Could not parse file.") if not so $parsed-file;

    my $evaluator = Kintsugi::Evaluator.new(source => $file.slurp);
    $evaluator.run($parsed-file.made);
    
    CATCH {
        when X::Kintsugi {
            .gist.say;
            exit;
        } 
    }
}
