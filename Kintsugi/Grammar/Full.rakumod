use Kintsugi::Grammar::Systems;

grammar Kintsugi::Grammar::Full is Kintsugi::Grammar::Systems {
    rule header { 'Kintsugi' '/Full'? <.ws> <block> }
    
    token datatype:sym<scope> { <scope> }
    token datatype:sym<operator> { <operator> | <mezzanine> }
    token datatype:sym<date> { <date> }
    token datatype:sym<logic> { <logic> }
    
    token scope {
        '@'
        < enter exit >
    }

    token mezzanine {
        | '|>'
    }
    
    token date {
        | \d ** 4 '-' \d ** 2 '-' \d ** 2
        | \d ** 2 '-' \d ** 2 '-' \d ** 2
        | \d ** 2 '-' \d ** 2 '-' \d ** 4
    }
    
    token logic {
        < true false on off yes no >
    }
}
