%token AS LET INTERFACE IMPL STRUCT ENUM UNION FN IF ELSE RETURN VAL CASE SWITCH
%token EQUALS
%token <string> IDENT
%token <string> STRING
%token EOF
%token REST 
%token LBRACE LPAREN
%token RBRACE RPAREN
%token COMMA
%token COLON RARROW REARROW SEMICOLON
%token TILDE DOT
%token <Z.t> INT
%token <bool> BOOL

%%
