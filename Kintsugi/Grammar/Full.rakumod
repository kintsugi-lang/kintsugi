use Kintsugi::Grammar::Systems;
grammar Kintsugi::Grammar::Full is Kintsugi::Grammar::Systems {
    rule header { 'Kintsugi' '/Full'? <.ws> <block> }

    token datatype:sym<date> { <date> }
    token datatype:sym<time> { <time> }
    token datatype:sym<pair> { <pair> }
    token datatype:sym<money> { <money> }
    token datatype:sym<tuple> { <tuple> }
    token datatype:sym<logic> { <logic> }

    token date {
        | \d ** 4 '-' \d ** 2 '-' \d ** 2
        | \d ** 2 '-' \d ** 2 '-' \d ** 2
        | \d ** 2 '-' \d ** 2 '-' \d ** 4
    }

    token time { \d ** 2 ':' \d ** 2 [ ':' \d ** 2 ]? }

    token pair { [<integer> | <float>] 'x' [<integer> | <float>] }
    token money { '$' [<integer> | <float>] }
    token tuple { <integer> '.' <integer> '.' [<integer> '.'?]+ }
    
    token logic {
        < true false on off yes no >
    }

    token binary-op { '->' | 'Z' }
}
