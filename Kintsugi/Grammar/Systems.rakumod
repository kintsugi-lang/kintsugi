use Kintsugi::Grammar::Core;

grammar Kintsugi::Grammar::Systems is Kintsugi::Grammar::Core {
    rule header { 'Kintsugi/Systems' <.ws> <block> }
    
    token datatype:sym<string> { <string> }
    token datatype:sym<logic> { <logic> }

    token string { '"' ~ '"' <string-contents> }
    token logic { < true false > }
}
