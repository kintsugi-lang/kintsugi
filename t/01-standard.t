use Test;
use lib 'lib';
use Kintsugi::Standard::Grammar;

Kintsugi::Standard::Grammar.parsefile($_).&isnt(Nil) for 't/test-files'.IO.dir;

done-testing;
