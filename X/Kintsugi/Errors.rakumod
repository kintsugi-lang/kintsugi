class X::Kintsugi is Exception {
    has Str $.message;
    method gist { "{self.^name}: {$.message}" }
}

class X::Kintsugi::StartupError is X::Kintsugi {}
class X::Kintsugi::UnknownDialectError is X::Kintsugi {}
class X::Kintsugi::ParseError is X::Kintsugi {}
class X::Kintsugi::UndefinedWord is X::Kintsugi {}
class X::Kintsugi::ArityError is X::Kintsugi {}
class X::Kintsugi::TypeError is X::Kintsugi {}
class X::Kintsugi::DuplicateParam is X::Kintsugi {}
