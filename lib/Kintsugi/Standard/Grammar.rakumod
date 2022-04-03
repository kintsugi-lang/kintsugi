use Kintsugi::Foundation::Grammar;

grammar Kintsugi::Standard::Grammar is Kintsugi::Foundation::Grammar {
    token header { 'Kintsugi' <.ws> <block> }

    token datatype:sym<scope> { <scope> }
    token datatype:sym<operator> { <operator> }
    token datatype:sym<date> { <date> }
    
    token scope {
        '@'
        [
            | 'enter'
            | 'exit'
        ]
    }

    token operator {
        | <[+\-*/\^=]>
        | '|>'
    }
    token date {
        | \d ** 4 '-' \d ** 2 '-' \d ** 2
        | \d ** 2 '-' \d ** 2 '-' \d ** 2
        | \d ** 2 '-' \d ** 2 '-' \d ** 4
    }
}
