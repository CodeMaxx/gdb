/* Bison parser for Rust expressions, for GDB.
   Copyright (C) 2016 Free Software Foundation, Inc.

   This file is part of GDB.

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <http://www.gnu.org/licenses/>.  */

/* Bison is way nicer than the old #define approach.  */
%define api.prefix {rust}

%{

#include "defs.h"

#include "block.h"
#include "charset.h"
#include "cp-support.h"
#include "gdb_obstack.h"
#include "gdb_regex.h"
#include "rust-lang.h"
#include "parser-defs.h"
#include "value.h"
#include "vec.h"

#ifndef RUSTDEBUG
#define	RUSTDEBUG 1		/* Default to debug support */
#endif

#define YYFPRINTF parser_fprintf

extern initialize_file_ftype _initialize_rust_exp;

static int rustlex (void);
static const char *rust_copy_name (const char *, int);
static struct stoken rust_concat3 (const char *, const char *, const char *);
static struct stoken make_stoken (const char *);
static void update_innermost_block (struct block_symbol);

struct rust_op;
typedef const struct rust_op *rust_op_ptr;
DEF_VEC_P (rust_op_ptr);

struct typed_val_int
{
  LONGEST val;
  struct type *type;
};

struct typed_val_float
{
  DOUBLEST dval;
  struct type *type;
};

struct set_field
{
  struct stoken name;
  const struct rust_op *init;
};

typedef struct set_field set_field;

DEF_VEC_O (set_field);

static struct type *rust_type (const char *name);

static const struct rust_op *make_operation (enum exp_opcode opcode,
					     const struct rust_op *left,
					     const struct rust_op *right);
static const struct rust_op *make_compound_assignment
  (enum exp_opcode opcode, const struct rust_op *left,
   const struct rust_op *rust_op);
static const struct rust_op *make_literal (struct typed_val_int val);
static const struct rust_op *make_dliteral (struct typed_val_float val);
static const struct rust_op *make_structop (const struct rust_op *left,
					    const char *name);
static const struct rust_op *make_unary (enum exp_opcode opcode,
					 const struct rust_op *expr);
static const struct rust_op *make_cast (const struct rust_op *expr,
					struct type *type);
static const struct rust_op *make_call_ish (enum exp_opcode opcode,
					    const struct rust_op *expr,
					    VEC (rust_op_ptr) *params);
static const struct rust_op *make_path (struct stoken name);
static const struct rust_op *make_string (struct stoken str);
static const struct rust_op *make_struct (struct stoken name,
					  VEC (set_field) *fields);

/* The state of the parser, used internally when we are parsing the
   expression.  */
static struct parser_state *pstate = NULL;

/* A regular expression for matching Rust numbers.  This is split up
   since it is very long and this gives us a way to comment the
   sections.  */
static const char *number_regex_text =
  /* subexpression 1: allows use of alternation, otherwise uninteresting */
  "^("
  /* First comes floating point.  */
  /* Recognize number after the decimal point, with optional
     exponent and optional type suffix.
     subexpression 2: allows "?", otherwise uninteresting
     subexpression 3: if present, type suffix
  */
  "[0-9][0-9_]*\\.[0-9][0-9_]*([eE][-+]?[0-9][0-9_]*)?(f32|f64)?"
#define FLOAT_TYPE1 3
  "|"
  /* Recognize exponent without decimal point, with optional type
     suffix.
     subexpression 4: if present, type suffix
  */
#define FLOAT_TYPE2 4
  "[0-9][0-9_]*[eE][-+]?[0-9][0-9_]*(f32|f64)?"
  "|"
  /* "23." is a valid floating point number, but "23.e5" and
     "23.f32" are not.  So, handle the trailing-. case
     separately.  */
  "[0-9][0-9_]*\\."
  "|"
  /* Finally come integers.
     subexpression 5: text of integer
     subexpression 6: if present, type suffix
     subexpression 7: allows use of alternation, otherwise uninteresting
  */
#define INT_TEXT 5
#define INT_TYPE 6
  "(0x[a-fA-F0-9_]+|0o[0-7_]+|0b[01_]+|[0-9][0-9_]*)"
  "([iu](size|8|16|32|64))?"
  ")";

/* The compiled number-matching regex.  */
static regex_t number_regex;

/* True if we're running unit tests.  */
static int unit_testing;

/* Obstack for data temporarily allocated during parsing.  */
static struct obstack work_obstack;

/* Result of parsing.  Points into work_obstack.  */
static const struct rust_op *rust_ast;

%}

%union
{
  struct typed_val_int typed_val_int;

  struct typed_val_float typed_val_float;

  struct stoken sval;

  enum exp_opcode opcode;

  struct type *type;

  VEC (rust_op_ptr) *params;

  VEC (set_field) *field_inits;

  const struct rust_op *op;

  int depth;
}

%token <sval> GDBVAR
%token <sval> IDENT
%token <sval> COMPLETE
%token <typed_val_int> INTEGER
%token <typed_val_int> DECIMAL_INTEGER
%token <sval> STRING
%token <sval> BYTESTRING
%token <typed_val_float> FLOAT
%token <opcode> COMPOUND_ASSIGN

/* Keyword tokens.  */
%token <voidval> KW_AS
%token <voidval> KW_IF
%token <voidval> KW_TRUE
%token <voidval> KW_FALSE
%token <voidval> KW_SUPER
%token <voidval> KW_SELF
%token <voidval> KW_MUT

/* Operator tokens.  */
%token <voidval> DOTDOT
%token <voidval> OROR
%token <voidval> ANDAND
%token <voidval> EQEQ
%token <voidval> NOTEQ
%token <voidval> LTEQ
%token <voidval> GTEQ
%token <voidval> LSH RSH
%token <voidval> COLONCOLON

%type <type> type

%type <sval> path
%type <sval> identifier_path
%type <sval> self_or_super_path

%type <depth> super_path

%type <op> literal
%type <op> expr
%type <op> field_expr
%type <op> idx_expr
%type <op> unop_expr
%type <op> binop_expr
%type <op> binop_expr_expr
%type <op> type_cast_expr
%type <op> assignment_expr
%type <op> compound_assignment_expr
%type <op> paren_expr
%type <op> call_expr
%type <op> path_expr
%type <op> tuple_expr
%type <op> unit_expr
%type <op> struct_expr
%type <op> array_expr
/* %type <op> range_expr */

%type <params> expr_list
%type <params> maybe_expr_list
%type <params> paren_expr_list

%type <field_inits> struct_expr_contents

/* Precedence.  */
%nonassoc DOTDOT
%right '=' COMPOUND_ASSIGN
%left OROR
%left ANDAND
%nonassoc EQEQ NOTEQ '<' '>' LTEQ GTEQ
%left '|'
%left '^'
%left '&'
%left LSH RSH
%left '@'
%left '+' '-'
%left '*' '/' '%' '[' '.' '('
%precedence UNARY
%left KW_AS

%%

start:
	expr
		{ rust_ast = $1; }
;

/* Note that the Rust grammar includes a method_call_expr, but we
   handle this differently, to avoid a shift/reduce conflict with
   call_expr.  */
expr:
	literal
|	path_expr
|	tuple_expr
|	unit_expr
|	struct_expr
|	field_expr
|	array_expr
|	idx_expr
/* |	range_expr */
|	unop_expr
|	binop_expr
|	paren_expr
|	call_expr
;

tuple_expr:
	'(' expr ',' maybe_expr_list ')'
		{
		  VEC_safe_insert (rust_op_ptr, $4, 0, $2);
		  error (_("tuple expressions not supported yet"));
		}
;

unit_expr:
	'(' ')'
		{
		  struct typed_val_int val;

		  val.type
		    = language_lookup_primitive_type (parse_language (pstate),
						      parse_gdbarch (pstate),
						      "()");
		  val.val = 0;
		  $$ = make_literal (val);
		}
;

/* To avoid a shift/reduce conflict with call_expr, we don't handle
   tuple struct expressions here, but instead when examining the
   AST.  */
struct_expr:
	path '{' struct_expr_contents '}'
		{ $$ = make_struct ($1, $3); }
|	path '{' DOTDOT expr '}'
		{
		  VEC (set_field) *result = NULL;
		  struct set_field sf;

		  sf.name.ptr = NULL;
		  sf.name.length = 0;
		  sf.init = $4;
		  VEC_safe_push (set_field, result, &sf);

		  $$ = make_struct ($1, result);
		}
;

/* The form S{.. expr} is handled directly in struct_expr, not here.
   S{} is documented as valid but seems to be an unstable feature, so
   it is left out here.

   Note that the rightmost element of the array ends up at index 0.
   This is compensated for when lowering from the AST.  */
struct_expr_contents:
	',' IDENT ':' expr
		{
		  struct set_field sf;

		  VEC (set_field) *result = NULL;
		  sf.name = $2;
		  sf.init = $4;
		  VEC_safe_push (set_field, result, &sf);
		  $$ = result;
		}
|	',' DOTDOT expr
		{
		  struct set_field sf;

		  VEC (set_field) *result = NULL;
		  sf.name.ptr = NULL;
		  sf.name.length = 0;
		  sf.init = $3;
		  VEC_safe_push (set_field, result, &sf);
		  $$ = result;
		}
|	IDENT ':' expr struct_expr_contents
		{
		  struct set_field sf;

		  sf.name = $1;
		  sf.init = $3;
		  VEC_safe_push (set_field, $4, &sf);
		  $$ = $4;
		}
;

array_expr:
	'[' KW_MUT expr_list ']'
		{ $$ = make_call_ish (OP_ARRAY, NULL, $3); }
|	'[' expr_list ']'
		{ $$ = make_call_ish (OP_ARRAY, NULL, $2); }
|	'[' KW_MUT expr ';' expr ']'
		{
		  error (_("[expr;expr] form of array not supported yet"));
		}
|	'[' expr ';' expr ']'
		{
		  error (_("[expr;expr] form of array not supported yet"));
		}
;

/* FIXME - this causes a shift/reduce conflict that I'd like to
   understand before implementing it.  */
/* range_expr: */
/* 	expr DOTDOT */
/* 		{ $$ = fixme; } */
/* |	expr DOTDOT expr */
/* 		{ $$ = fixme; } */
/* |	DOTDOT expr */
/* 		{ $$ = fixme; } */
/* |	DOTDOT */
/* 		{ $$ = fixme; } */
/* ; */

literal:
	INTEGER
		{ $$ = make_literal ($1); }
|	DECIMAL_INTEGER
		{ $$ = make_literal ($1); }
|	FLOAT
		{ $$ = make_dliteral ($1); }
|	STRING
		{
		  const struct rust_op *str = make_string ($1);
		  VEC (set_field) *fields = NULL;
		  struct set_field field;
		  struct typed_val_int val;
		  struct stoken token;

		  /* Wrap the raw string in the &str struct.  */
		  field.name.ptr = "data_ptr";
		  field.name.length = strlen (field.name.ptr);
		  field.init = make_unary (UNOP_ADDR, make_string ($1));
		  VEC_safe_push (set_field, fields, &field);

		  val.type = rust_type ("usize");
		  val.val = $1.length;

		  field.name.ptr = "length";
		  field.name.length = strlen (field.name.ptr);
		  field.init = make_literal (val);
		  VEC_safe_push (set_field, fields, &field);

		  token.ptr = "&str";
		  token.length = strlen (token.ptr);
		  $$ = make_struct (token, fields);
		}
|	BYTESTRING
		{ $$ = make_string ($1); }
|	KW_TRUE
		{
		  struct typed_val_int val;

		  val.type = language_bool_type (parse_language (pstate),
						 parse_gdbarch (pstate));
		  val.val = 1;
		  $$ = make_literal (val);
		}
|	KW_FALSE
		{
		  struct typed_val_int val;

		  val.type = language_bool_type (parse_language (pstate),
						 parse_gdbarch (pstate));
		  val.val = 0;
		  $$ = make_literal (val);
		}
;

field_expr:
	expr '.' IDENT
		{ $$ = make_structop ($1, $3.ptr); }
|	expr '.' DECIMAL_INTEGER
		{
		  /* We should perhaps represent this at a higher
		     level of abstraction, but for now we just bake in
		     the naming scheme used by rustc for tuple
		     fields.  */
		  struct stoken value = rust_concat3 ("__", plongest ($3.val),
						      NULL);
		  $$ = make_structop ($1, value.ptr);
		}
;

idx_expr:
	expr '[' expr ']'
		{ $$ = make_operation (BINOP_SUBSCRIPT, $1, $3); }
;

unop_expr:
	'+' expr	%prec UNARY
		{ $$ = make_unary (UNOP_PLUS, $2); }

|	'-' expr	%prec UNARY
		{ $$ = make_unary (UNOP_NEG, $2); }

|	'!' expr	%prec UNARY
		{
		  /* Note that we provide a Rust-specific evaluator
		     override for UNOP_COMPLEMENT, so it can do the
		     right thing for both bool and integral
		     values.  */
		  $$ = make_unary (UNOP_COMPLEMENT, $2);
		}

|	'*' expr	%prec UNARY
		{ $$ = make_unary (UNOP_IND, $2); }

|	'&' expr	%prec UNARY
		{ $$ = make_unary (UNOP_ADDR, $2); }

|	'&' KW_MUT expr	%prec UNARY
		{ $$ = make_unary (UNOP_ADDR, $3); }

;

binop_expr:
	binop_expr_expr
|	type_cast_expr
|	assignment_expr
|	compound_assignment_expr
;

binop_expr_expr:
	expr '*' expr
		{ $$ = make_operation (BINOP_MUL, $1, $3); }

|	expr '@' expr
		{ $$ = make_operation (BINOP_REPEAT, $1, $3); }

|	expr '/' expr
		{ $$ = make_operation (BINOP_DIV, $1, $3); }

|	expr '%' expr
		{ $$ = make_operation (BINOP_REM, $1, $3); }

|	expr '<' expr
		{ $$ = make_operation (BINOP_LESS, $1, $3); }

|	expr '>' expr
		{ $$ = make_operation (BINOP_GTR, $1, $3); }

|	expr '&' expr
		{ $$ = make_operation (BINOP_BITWISE_AND, $1, $3); }

|	expr '|' expr
		{ $$ = make_operation (BINOP_BITWISE_IOR, $1, $3); }

|	expr '^' expr
		{ $$ = make_operation (BINOP_BITWISE_XOR, $1, $3); }

|	expr '+' expr
		{ $$ = make_operation (BINOP_ADD, $1, $3); }

|	expr '-' expr
		{ $$ = make_operation (BINOP_SUB, $1, $3); }

|	expr OROR expr
		{ $$ = make_operation (BINOP_LOGICAL_OR, $1, $3); }

|	expr ANDAND expr
		{ $$ = make_operation (BINOP_LOGICAL_AND, $1, $3); }

|	expr EQEQ expr
		{ $$ = make_operation (BINOP_EQUAL, $1, $3); }

|	expr NOTEQ expr
		{ $$ = make_operation (BINOP_NOTEQUAL, $1, $3); }

|	expr LTEQ expr
		{ $$ = make_operation (BINOP_LEQ, $1, $3); }

|	expr GTEQ expr
		{ $$ = make_operation (BINOP_GEQ, $1, $3); }

|	expr LSH expr
		{ $$ = make_operation (BINOP_LSH, $1, $3); }

|	expr RSH expr
		{ $$ = make_operation (BINOP_RSH, $1, $3); }
;

type_cast_expr:
	expr KW_AS type
		{ $$ = make_cast ($1, $3); }
;

assignment_expr:
	expr '=' expr
		{ $$ = make_operation (BINOP_ASSIGN, $1, $3); }
;

compound_assignment_expr:
	expr COMPOUND_ASSIGN expr
		{ $$ = make_compound_assignment ($2, $1, $3); }

;

paren_expr:
	'(' expr ')'
		{ $$ = $2; }
;

expr_list:
	expr
		{
		  $$ = NULL;
		  VEC_safe_push (rust_op_ptr, $$, $1);
		}
|	expr_list ',' expr
		{
		  VEC_safe_push (rust_op_ptr, $1, $3);
		  $$ = $1;
		}
;

maybe_expr_list:
	%empty
		{ $$ = NULL; }
|	expr_list
		{ $$ = $1; }
;

paren_expr_list:
	'('
	maybe_expr_list
	')'
		{ $$ = $2; }
;

call_expr:
	expr paren_expr_list
		{ $$ = make_call_ish (OP_FUNCALL, $1, $2); }
;

path_expr:
	path
		{ $$ = make_path ($1); }
|	GDBVAR
		{ $$ = make_path ($1); }
;

path:
	identifier_path
|	self_or_super_path
|	COLONCOLON identifier_path
		{ $$ = rust_concat3 ("::", $2.ptr, NULL); }
;

identifier_path:
	IDENT
|	IDENT COLONCOLON identifier_path
		{ $$ = rust_concat3 ($1.ptr, "::", $3.ptr); }
;

maybe_self_path:
	%empty
|	KW_SELF COLONCOLON
;

self_or_super_path:
	maybe_self_path identifier_path
		{
		  const char *scope = block_scope (expression_context_block);

		  if (scope[0] == '\0')
		    error (_("couldn't find namespace scope for self::"));

		  $$ = rust_concat3 (scope, "::", $2.ptr);
		}
|	maybe_self_path super_path identifier_path
		{
		  const char *scope = block_scope (expression_context_block);
		  int i;
		  unsigned int len, offset;

		  if (scope[0] == '\0')
		    error (_("couldn't find namespace scope for self::"));

		  len = cp_entire_prefix_len (scope);
		  if ($2 >= len)
		    error (_("too many super:: uses from '%s'"), scope);

		  for (i = offset = 0; i < $2; ++i)
		    {
		      offset = cp_find_first_component (&scope[offset]);
		      /* The "+ 2" is for the "::".  */
		      offset += 2;
		    }

		  obstack_grow (&work_obstack, scope, offset);
		  obstack_grow0 (&work_obstack, $3.ptr, $3.length);
		  $$ = make_stoken (obstack_finish (&work_obstack));
		}
;

super_path:
	KW_SUPER COLONCOLON
		{ $$ = 1; }
|	KW_SUPER COLONCOLON super_path
		{ $$ = $3 + 1; }
;

type:
	path
		{
		  $$ = lookup_typename (parse_language (pstate),
					parse_gdbarch (pstate),
					$1.ptr, NULL, 0);
		}
;


%%

/* A struct of this type is used to describe a token.  */
struct token_info
{
  const char *name;
  int value;
  enum exp_opcode opcode;
};

/* Identifier tokens.  */
static const struct token_info identifier_tokens[] =
{
  { "as", KW_AS, OP_NULL },
  { "false", KW_FALSE, OP_NULL },
  { "if", 0, OP_NULL },
  { "mut", KW_MUT, OP_NULL },
  { "self", KW_SELF, OP_NULL },
  { "super", KW_SUPER, OP_NULL },
  { "true", KW_TRUE, OP_NULL },
};

/* Operator tokens, sorted longest first.  */
static const struct token_info operator_tokens[] =
{
  { ">>=", COMPOUND_ASSIGN, BINOP_RSH },
  { "<<=", COMPOUND_ASSIGN, BINOP_LSH },

  { "<<", LSH, OP_NULL },
  { ">>", RSH, OP_NULL },
  { "&&", ANDAND, OP_NULL },
  { "||", OROR, OP_NULL },
  { "==", EQEQ, OP_NULL },
  { "!=", NOTEQ, OP_NULL },
  { "<=", LTEQ, OP_NULL },
  { ">=", GTEQ, OP_NULL },
  { "+=", COMPOUND_ASSIGN, BINOP_ADD },
  { "-=", COMPOUND_ASSIGN, BINOP_SUB },
  { "*=", COMPOUND_ASSIGN, BINOP_MUL },
  { "/=", COMPOUND_ASSIGN, BINOP_DIV },
  { "%=", COMPOUND_ASSIGN, BINOP_REM },
  { "&=", COMPOUND_ASSIGN, BINOP_BITWISE_AND },
  { "|=", COMPOUND_ASSIGN, BINOP_BITWISE_IOR },
  { "^=", COMPOUND_ASSIGN, BINOP_BITWISE_XOR },

  { "::", COLONCOLON, OP_NULL },
  { "..", DOTDOT, OP_NULL }
};

/* Helper function to copy to the name obstack.  */
static const char *
rust_copy_name (const char *name, int len)
{
  return obstack_copy0 (&work_obstack, name, len);
}

/* Helper function to make an stoken from a C string.  */
static struct stoken
make_stoken (const char *p)
{
  struct stoken result;

  result.ptr = p;
  result.length = strlen (result.ptr);
  return result;
}

/* Helper function to concatenate three strings on the name
   obstack.  */
static struct stoken
rust_concat3 (const char *s1, const char *s2, const char *s3)
{
  return make_stoken (obconcat (&work_obstack, s1, s2, s3, (char *) NULL));
}

/* A helper that updates innermost_block as appropriate.  */
static void
update_innermost_block (struct block_symbol sym)
{
  if (symbol_read_needs_frame (sym.symbol)
      && (innermost_block == NULL
	  || contained_in (sym.block, innermost_block)))
    innermost_block = sym.block;
}

/* A helper to look up a Rust type, or fail.  This only works for
   types defined by rust_language_arch_info.  */
static struct type *
rust_type (const char *name)
{
  struct type *type;

  if (unit_testing)
    return NULL;

  type = language_lookup_primitive_type (parse_language (pstate),
					 parse_gdbarch (pstate),
					 name);
  if (type == NULL)
    error (_("could not find Rust type %s"), name);
  return type;
}

/* Lex a hex number with at least MIN digits and at most MAX
   digits.  */
static uint32_t
lex_hex (int min, int max)
{
  uint32_t result = 0;
  int len = 0;

  while (len <= max
	 && ((lexptr[0] >= 'a' && lexptr[0] <= 'f')
	     || (lexptr[0] >= 'A' && lexptr[0] <= 'F')
	     || (lexptr[0] >= '0' && lexptr[0] <= '9')))
    {
      result *= 16;
      if (lexptr[0] >= 'a' && lexptr[0] <= 'f')
	result = result + 10 + lexptr[0] - 'a';
      else if (lexptr[0] >= 'A' && lexptr[0] <= 'F')
	result = result + 10 + lexptr[0] - 'A';
      else
	result = result + lexptr[0] - '0';
      ++lexptr;
      ++len;
    }

  if (len < min)
    error (_("Not enough hex digits seen"));
  if (len > max)
    error (_("Overlong hex number"));

  return result;
}

/* Lex an escape.  IS_BYTE is true if we're lexing a byte escape;
   otherwise we're lexing a character escape.  */
static uint32_t
lex_escape (int is_byte)
{
  uint32_t result;

  gdb_assert (lexptr[0] == '\\');
  ++lexptr;
  switch (lexptr[0])
    {
    case 'x':
      ++lexptr;
      result = lex_hex (2, 2);
      break;

    case 'u':
      if (is_byte)
	error (_("Unicode escape in byte literal"));
      ++lexptr;
      if (lexptr[0] != '{')
	error (_("Missing '{' in Unicode escape"));
      ++lexptr;
      result = lex_hex (1, 6);
      /* FIXME check surrogate, other range stuff */
      if (lexptr[0] != '}')
	error (_("Missing '}' in Unicode escape"));
      ++lexptr;
      break;

    case 'n':
      result = '\n';
      ++lexptr;
      break;
    case 'r':
      result = '\r';
      ++lexptr;
      break;
    case 't':
      result = '\t';
      ++lexptr;
      break;
    case '\\':
      result = '\\';
      ++lexptr;
      break;
    case '0':
      result = '\0';
      ++lexptr;
      break;
    case '\'':
      result = '\'';
      ++lexptr;
      break;
    case '"':
      result = '"';
      ++lexptr;
      break;

    default:
      error (_("Invalid escape \\%c in literal"), lexptr[0]);
    }

  return result;
}

/* Lex a character constant.  */
static int
lex_character (void)
{
  int is_byte = 0;
  uint32_t value;

  if (lexptr[0] == 'b')
    {
      is_byte = 1;
      ++lexptr;
    }
  gdb_assert (lexptr[0] == '\'');
  ++lexptr;
  /* FIXME: in character case, read a whole UTF-8 character here --
     but really at a higher level we need to convert from the host
     charset to UTF-8 or maybe UTF-32.  */
  if (lexptr[0] == '\\')
    value = lex_escape (is_byte);
  else
    {
      value = lexptr[0] & 0xff;
      ++lexptr;
    }

  if (lexptr[0] != '\'')
    error (_("Unterminated character literal"));
  ++lexptr;

  rustlval.typed_val_int.val = value;
  rustlval.typed_val_int.type = rust_type (is_byte ? "u8" : "char");

  return INTEGER;
}

/* Return the offset of the double quote if STR looks like the start
   of a raw string, or 0 if STR does not start a raw string..  */
static int
starts_raw_string (const char *str)
{
  const char *save = str;

  if (str[0] != 'r')
    return 0;
  ++str;
  while (str[0] == '#')
    ++str;
  if (str[0] == '"')
    return str - save;
  return 0;
}

/* Return true if STR looks like the end of a raw string that had N
   hashes at the start.  */
static int
ends_raw_string (const char *str, int n)
{
  int i;

  gdb_assert (str[0] == '"');
  for (i = 0; i < n; ++i)
    if (str[i + 1] != '#')
      return 0;
  return 1;
}

/* Lex a string constant.  */
static int
lex_string (void)
{
  int is_byte = lexptr[0] == 'b';
  int raw_length;
  int len_in_chars = 0;

  if (is_byte)
    ++lexptr;
  raw_length = starts_raw_string (lexptr);
  lexptr += raw_length;
  gdb_assert (lexptr[0] == '"');
  ++lexptr;

  while (1)
    {
      uint32_t value;

      if (raw_length > 0)
	{
	  if (lexptr[0] == '"' && ends_raw_string (lexptr, raw_length - 1))
	    {
	      /* Exit with lexptr pointing after the final "#".  */
	      lexptr += raw_length;
	      break;
	    }

	  value = lexptr[0] & 0xff;
	  if (is_byte && value > 127)
	    error (_("non-ASCII value in raw byte string"));
	  obstack_1grow (&work_obstack, value);

	  ++lexptr;
	}
      else if (lexptr[0] == '"')
	{
	  /* Make sure to skip the quote.  */
	  ++lexptr;
	  break;
	}
      else if (lexptr[0] == '\\')
	{
	  value = lex_escape (is_byte);

	  if (is_byte)
	    obstack_1grow (&work_obstack, value);
	  else
	    convert_between_encodings ("UTF-32", "UTF-8", (gdb_byte *) &value,
				       sizeof (value), sizeof (value),
				       &work_obstack, translit_none);
	}
      else
	{
	  value = lexptr[0] & 0xff;
	  if (is_byte && value > 127)
	    error (_("non-ASCII value in raw byte string"));
	  obstack_1grow (&work_obstack, value);
	  ++lexptr;
	}
    }

  rustlval.sval.length = obstack_object_size (&work_obstack);
  rustlval.sval.ptr = obstack_finish (&work_obstack);
  return is_byte ? BYTESTRING : STRING;
}

/* Return true if STRING starts with whitespace followed by a digit.  */
static int
space_then_number (const char *string)
{
  const char *p = string;

  while (p[0] == ' ' || p[0] == '\t')
    ++p;
  if (p == string)
    return 0;

  return *p >= '0' && *p <= '9';
}

/* Lex an identifier.  */
static int
lex_identifier (void)
{
  const char *start = lexptr;
  unsigned int length;
  const struct token_info *token;
  int i;
  int is_gdb_var = lexptr[0] == '$';

  gdb_assert ((lexptr[0] >= 'a' && lexptr[0] <= 'z')
	      || (lexptr[0] >= 'A' && lexptr[0] <= 'Z')
	      || lexptr[0] == '_' || lexptr[0] == '$');

  ++lexptr;

  /* FIXME Unicode rules */
  while ((lexptr[0] >= 'a' && lexptr[0] <= 'z')
	 || (lexptr[0] >= 'A' && lexptr[0] <= 'Z')
	 || lexptr[0] == '_'
	 || (is_gdb_var && lexptr[0] == '$')
	 || (lexptr[0] >= '0' && lexptr[0] <= '9'))
    ++lexptr;


  length = lexptr - start;
  token = NULL;
  for (i = 0; i < ARRAY_SIZE (identifier_tokens); ++i)
    {
      if (length == strlen (identifier_tokens[i].name)
	  && strncmp (identifier_tokens[i].name, start, length) == 0)
	{
	  token = &identifier_tokens[i];
	  break;
	}
    }

  if (token == NULL)
    {
      if ((strncmp (start, "thread", length) == 0
	   || strncmp (start, "task", length) == 0)
	  && space_then_number (lexptr))
	{
	  /* "task" or "thread" followed by a number terminates the
	     parse, per gdb rules.  */
	  lexptr = start;
	  return 0;
	}
    }
  else
    {
      if (token->value == 0)
	{
	  /* Leave the terminating token alone.  */
	  lexptr = start;
	}

      return token->value;
    }

  rustlval.sval = make_stoken (rust_copy_name (start, length));

  /* Slightly weird that we don't allow completion if the text happens
     to be a token or a convenience variable.  FIXME - we need a
     slightly better completion scheme perhaps.  */
  if (is_gdb_var)
    return GDBVAR;
  if (parse_completion && lexptr[0] == '\0')
    return COMPLETE;
  return IDENT;
}

/* Lex an operator.  */
static int
lex_operator (void)
{
  const struct token_info *token = NULL;
  int i;

  for (i = 0; i < ARRAY_SIZE (operator_tokens); ++i)
    {
      if (strncmp (operator_tokens[i].name, lexptr,
		   strlen (operator_tokens[i].name)) == 0)
	{
	  lexptr += strlen (operator_tokens[i].name);
	  token = &operator_tokens[i];
	  break;
	}
    }

  if (token != NULL)
    {
      rustlval.opcode = token->opcode;
      return token->value;
    }

  return *lexptr++;
}

/* Lex a number.  */
static int
lex_number (void)
{
  regmatch_t subexps[8];
  int match;
  int is_integer = 0;
  int could_be_decimal = 1;
  char *typename = NULL;
  struct type *type;
  int end_index;
  int type_index = -1;
  int i, out;
  char *number;
  struct cleanup *cleanup = make_cleanup (null_cleanup, NULL);

  match = regexec (&number_regex, lexptr, ARRAY_SIZE (subexps), subexps, 0);
  /* Failure means the regexp is broken.  */
  gdb_assert (!match);

  if (subexps[INT_TEXT].rm_so != -1)
    {
      /* Integer part matched.  */
      is_integer = 1;
      end_index = subexps[INT_TEXT].rm_eo;
      if (subexps[INT_TYPE].rm_so == -1)
	typename = "i32";
      else
	{
	  type_index = INT_TYPE;
	  could_be_decimal = 0;
	}
    }
  else if (subexps[FLOAT_TYPE1].rm_so != -1)
    {
      /* Found floating point type suffix.  */
      end_index = subexps[FLOAT_TYPE1].rm_so;
      type_index = FLOAT_TYPE1;
    }
  else if (subexps[FLOAT_TYPE2].rm_so != -1)
    {
      /* Found floating point type suffix.  */
      end_index = subexps[FLOAT_TYPE2].rm_so;
      type_index = FLOAT_TYPE2;
    }
  else
    {
      /* Any other floating point match.  */
      end_index = subexps[0].rm_eo;
      typename = "f64";
    }

  /* Compute the type name if we haven't already.  */
  if (typename == NULL)
    {
      gdb_assert (type_index != -1);
      typename = xstrndup (lexptr + subexps[type_index].rm_so,
			   (subexps[type_index].rm_eo
			    - subexps[type_index].rm_so));
      make_cleanup (xfree, typename);
    }

  /* Look up the type.  */
  type = rust_type (typename);

  /* Copy the text of the number and remove the "_"s.  */
  number = xstrndup (lexptr, end_index);
  make_cleanup (xfree, number);
  for (i = out = 0; number[i]; ++i)
    {
      if (number[i] == '_')
	could_be_decimal = 0;
      else
	number[out++] = number[i];
    }
  number[out] = '\0';

  /* Advance past the match.  */
  lexptr += subexps[0].rm_eo;

  /* Parse the number.  */
  if (is_integer)
    {
      int radix = 10;
      if (number[0] == '0')
	{
	  if (number[1] == 'x')
	    radix = 16;
	  else if (number[1] == 'o')
	    radix = 8;
	  else if (number[1] == 'b')
	    radix = 2;
	  if (radix != 10)
	    {
	      number += 2;
	      could_be_decimal = 0;
	    }
	}
      rustlval.typed_val_int.val = strtoul (number, NULL, radix);
      rustlval.typed_val_int.type = type;
    }
  else
    {
      rustlval.typed_val_float.dval = strtod (number, NULL);
      rustlval.typed_val_float.type = type;
    }

  do_cleanups (cleanup);
  return is_integer ? (could_be_decimal ? DECIMAL_INTEGER : INTEGER) : FLOAT;
}

/* The lexer.  */
static int
rustlex (void)
{
  /* Skip all leading whitespace.  */
  while (lexptr[0] == ' ' || lexptr[0] == '\t' || lexptr[0] == '\r'
	 || lexptr[0] == '\n')
    ++lexptr;

  prev_lexptr = lexptr;
  if (lexptr[0] == 0)
    return 0;

  if (lexptr[0] >= '0' && lexptr[0] <= '9')
    return lex_number ();
  else if (lexptr[0] == 'b' && lexptr[1] == '\'')
    return lex_character ();
  else if (lexptr[0] == 'b' && lexptr[1] == '"')
    return lex_string ();
  else if (lexptr[0] == 'b' && starts_raw_string (lexptr + 1))
    return lex_string ();
  else if (starts_raw_string (lexptr))
    return lex_string ();
  else if ((lexptr[0] >= 'a' && lexptr[0] <= 'z')
	   || (lexptr[0] >= 'A' && lexptr[0] <= 'Z')
	   || lexptr[0] == '_' || lexptr[0] == '$')
    return lex_identifier ();
  else if (lexptr[0] == '"')
    return lex_string ();
  else if (lexptr[0] == '\'')
    return lex_character ();
  else if (lexptr[0] == '}' || lexptr[0] == ']')
    {
      /* Falls through to lex_operator.  */
      --paren_depth;
    }
  else if (lexptr[0] == '(' || lexptr[0] == '{')
    {
      /* Falls through to lex_operator.  */
      ++paren_depth;
    }
  else if (lexptr[0] == ',' && comma_terminates && paren_depth == 0)
    return 0;

  return lex_operator ();
}



/* Rust AST operations.  Our own mini-AST is the cleanest way to solve
   the type/expr ambiguity.  Rust itself isn't ambiguous but gdb
   pretty much requires that the parser accept a type as well as an
   expression, and this introduces ambiguity.  */

struct rust_op
{
  enum exp_opcode opcode;
  unsigned int compound_assignment : 1;
  RUSTSTYPE left;
  RUSTSTYPE right;
};

static const struct rust_op *
make_operation (enum exp_opcode opcode, const struct rust_op *left,
		const struct rust_op *right)
{
  struct rust_op *result = OBSTACK_ZALLOC (&work_obstack, struct rust_op);

  result->opcode = opcode;
  result->left.op = left;
  result->right.op = right;

  return result;
}

static const struct rust_op *
make_compound_assignment (enum exp_opcode opcode, const struct rust_op *left,
			  const struct rust_op *right)
{
  struct rust_op *result = OBSTACK_ZALLOC (&work_obstack, struct rust_op);

  result->opcode = opcode;
  result->compound_assignment = 1;
  result->left.op = left;
  result->right.op = right;

  return result;
}

static const struct rust_op *
make_literal (struct typed_val_int val)
{
  struct rust_op *result = OBSTACK_ZALLOC (&work_obstack, struct rust_op);

  result->opcode = OP_LONG;
  result->left.typed_val_int = val;

  return result;
}

static const struct rust_op *
make_dliteral (struct typed_val_float val)
{
  struct rust_op *result = OBSTACK_ZALLOC (&work_obstack, struct rust_op);

  result->opcode = OP_DOUBLE;
  result->left.typed_val_float = val;

  return result;
}

static const struct rust_op *
make_unary (enum exp_opcode opcode, const struct rust_op *expr)
{
  return make_operation (opcode, expr, NULL);
}

static const struct rust_op *
make_cast (const struct rust_op *expr, struct type *type)
{
  struct rust_op *result = OBSTACK_ZALLOC (&work_obstack, struct rust_op);

  result->opcode = UNOP_CAST;
  result->left.op = expr;
  result->right.type = type;

  return result;
}

static const struct rust_op *
make_call_ish (enum exp_opcode opcode, const struct rust_op *expr,
	       VEC (rust_op_ptr) *params)
{
  struct rust_op *result = OBSTACK_ZALLOC (&work_obstack, struct rust_op);

  result->opcode = opcode;
  result->left.op = expr;
  result->right.params = params;

  return result;
}

static const struct rust_op *
make_struct (struct stoken name, VEC (set_field) *fields)
{
  struct rust_op *result = OBSTACK_ZALLOC (&work_obstack, struct rust_op);

  /* We treat this differently than Ada.  */
  result->opcode = OP_AGGREGATE;
  result->left.sval = name;
  result->right.field_inits = fields;

  return result;
}

static const struct rust_op *
make_path (struct stoken path)
{
  struct rust_op *result = OBSTACK_ZALLOC (&work_obstack, struct rust_op);

  result->opcode = OP_VAR_VALUE;
  result->left.sval = path;

  return result;
}

static const struct rust_op *
make_string (struct stoken str)
{
  struct rust_op *result = OBSTACK_ZALLOC (&work_obstack, struct rust_op);

  result->opcode = OP_STRING;
  result->left.sval = str;

  return result;
}

static const struct rust_op *
make_structop (const struct rust_op *left, const char *name)
{
  struct rust_op *result = OBSTACK_ZALLOC (&work_obstack, struct rust_op);

  result->opcode = STRUCTOP_STRUCT;
  result->left.op = left;
  result->right.sval = make_stoken (name);

  return result;
}

static void convert_ast_to_expression (struct parser_state *state,
				       const struct rust_op *operation,
				       const struct rust_op *top);

static void
convert_params_to_expression (struct parser_state *state,
			      VEC (rust_op_ptr) *params,
			      const struct rust_op *top)
{
  int i;
  rust_op_ptr elem;

  for (i = 0; VEC_iterate (rust_op_ptr, params, i, elem); ++i)
    convert_ast_to_expression (state, elem, top);
}

/* Like lookup_symbol, but handles Rust namespace conventions, and
   doesn't require field_of_this_result.  */

static struct block_symbol
rust_lookup_symbol (const char *name, const struct block *block,
		    const domain_enum domain)
{
  /* FIXME this approach is rather bad and instead we want to
     construct an AST for paths as well, so we can be intelligent
     about lookups and canonicalization.  */
  if (strncmp (name, "::", 2) == 0)
    {
      name += 2;
      block = block_static_block (block);
    }

  return lookup_symbol (name, block, domain, NULL);
}

static void
convert_ast_to_expression (struct parser_state *state,
			   const struct rust_op *operation,
			   const struct rust_op *top)
{
  switch (operation->opcode)
    {
    case OP_LONG:
      write_exp_elt_opcode (state, OP_LONG);
      write_exp_elt_type (state, operation->left.typed_val_int.type);
      write_exp_elt_longcst (state, operation->left.typed_val_int.val);
      write_exp_elt_opcode (state, OP_LONG);
      break;

    case OP_DOUBLE:
      write_exp_elt_opcode (state, OP_DOUBLE);
      write_exp_elt_type (state, operation->left.typed_val_float.type);
      write_exp_elt_dblcst (state, operation->left.typed_val_float.dval);
      write_exp_elt_opcode (state, OP_DOUBLE);
      break;

    case STRUCTOP_STRUCT:
      {
	convert_ast_to_expression (state, operation->left.op, top);

	write_exp_elt_opcode (state, STRUCTOP_STRUCT);
	write_exp_string (state, operation->right.sval);
	write_exp_elt_opcode (state, STRUCTOP_STRUCT);
      }
      break;

    case UNOP_PLUS:
    case UNOP_NEG:
    case UNOP_COMPLEMENT:
    case UNOP_IND:
    case UNOP_ADDR:
      convert_ast_to_expression (state, operation->left.op, top);
      write_exp_elt_opcode (state, operation->opcode);
      break;

    case BINOP_SUBSCRIPT:
    case BINOP_MUL:
    case BINOP_REPEAT:
    case BINOP_DIV:
    case BINOP_REM:
    case BINOP_LESS:
    case BINOP_GTR:
    case BINOP_BITWISE_AND:
    case BINOP_BITWISE_IOR:
    case BINOP_BITWISE_XOR:
    case BINOP_ADD:
    case BINOP_SUB:
    case BINOP_LOGICAL_OR:
    case BINOP_LOGICAL_AND:
    case BINOP_EQUAL:
    case BINOP_NOTEQUAL:
    case BINOP_LEQ:
    case BINOP_GEQ:
    case BINOP_LSH:
    case BINOP_RSH:
    case BINOP_ASSIGN:
      convert_ast_to_expression (state, operation->left.op, top);
      convert_ast_to_expression (state, operation->right.op, top);
      if (operation->compound_assignment)
	{
	  write_exp_elt_opcode (state, BINOP_ASSIGN_MODIFY);
	  write_exp_elt_opcode (state, operation->opcode);
	  write_exp_elt_opcode (state, BINOP_ASSIGN_MODIFY);
	}
      else
	write_exp_elt_opcode (state, operation->opcode);

      if (operation->compound_assignment
	  || operation->opcode == BINOP_ASSIGN)
	{
	  struct type *type;

	  type = language_lookup_primitive_type (parse_language (state),
						 parse_gdbarch (state),
						 "()");

	  write_exp_elt_opcode (state, OP_LONG);
	  write_exp_elt_type (state, type);
	  write_exp_elt_longcst (state, 0);
	  write_exp_elt_opcode (state, OP_LONG);

	  write_exp_elt_opcode (state, BINOP_COMMA);
	}
      break;

    case UNOP_CAST:
      convert_ast_to_expression (state, operation->left.op, top);
      write_exp_elt_opcode (state, UNOP_CAST);
      write_exp_elt_type (state, operation->right.type);
      write_exp_elt_opcode (state, UNOP_CAST);
      break;

    case OP_FUNCALL:
      write_exp_elt_opcode (state, OP_FUNCALL);
      write_exp_elt_longcst (state, VEC_length (rust_op_ptr,
						operation->right.params) - 1);
      write_exp_elt_longcst (state, OP_FUNCALL);
      convert_ast_to_expression (state, operation->left.op, top);
      convert_params_to_expression (state, operation->right.params, top);
      break;

    case OP_ARRAY:
      gdb_assert (operation->left.op == NULL);
      convert_params_to_expression (state, operation->right.params, top);
      write_exp_elt_opcode (state, OP_ARRAY);
      write_exp_elt_longcst (state, 0);
      write_exp_elt_longcst (state, VEC_length (rust_op_ptr,
						operation->right.params) - 1);
      write_exp_elt_longcst (state, OP_ARRAY);
      break;

    case OP_VAR_VALUE:
      {
	struct block_symbol sym;

	if (operation->left.sval.ptr[0] == '$')
	  {
	    write_dollar_variable (state, operation->left.sval);
	    break;
	  }

	sym = rust_lookup_symbol (operation->left.sval.ptr,
				  expression_context_block,
				  VAR_DOMAIN);
	if (sym.symbol != NULL)
	  {
	    update_innermost_block (sym);
	    write_exp_elt_opcode (state, OP_VAR_VALUE);
	    write_exp_elt_block (state, sym.block);
	    write_exp_elt_sym (state, sym.symbol);
	    write_exp_elt_opcode (state, OP_VAR_VALUE);
	  }
	else
	  {
	    if (operation == top)
	      {
		/* If we didn't find a variable, and we're at the top
		   level, then maybe we found a type instead.  */
		struct type *type;

		/* First try a type tag.  */
		sym = rust_lookup_symbol (operation->left.sval.ptr,
					  expression_context_block,
					  STRUCT_DOMAIN);
		if (sym.symbol != NULL)
		  {
		    update_innermost_block (sym);
		    type = SYMBOL_TYPE (sym.symbol);
		  }
		else
		  type = lookup_typename (parse_language (state),
					  parse_gdbarch (state),
					  operation->left.sval.ptr,
					  NULL, 0);

		if (type != NULL)
		  {
		    write_exp_elt_opcode (state, OP_TYPE);
		    write_exp_elt_type (state, type);
		    write_exp_elt_opcode (state, OP_TYPE);
		    break;
		  }
	      }

	    error (_("No symbol '%s' in current context"),
		   operation->left.sval.ptr);
	  }
      }
      break;

    case OP_AGGREGATE:
      {
	int i;
	int length;
	const struct set_field *init;
	VEC (set_field) *fields = operation->right.field_inits;
	struct type *type;

	/* We constructed the initializers in reverse order; but if
	   the final one is a copy initializer, then we want to
	   process it first.  */
	length = 0;
	for (i = VEC_length (set_field, fields) - 1;
	     i >= 0;
	     --i)
	  {
	    init = VEC_index (set_field, fields, i);

	    if (init->name.ptr != NULL)
	      {
		write_exp_elt_opcode (state, OP_NAME);
		write_exp_string (state, init->name);
		write_exp_elt_opcode (state, OP_NAME);
		++length;
	      }

	    convert_ast_to_expression (state, init->init, top);
	    ++length;

	    if (init->name.ptr == NULL)
	      {
		/* This is handled differently from Ada in our
		   evaluator.  */
		write_exp_elt_opcode (state, OP_OTHERS);
	      }
	  }

	type = lookup_typename (parse_language (state),
				parse_gdbarch (state),
				operation->left.sval.ptr,
				NULL, 0);

	write_exp_elt_opcode (state, OP_AGGREGATE);
	write_exp_elt_type (state, type);
	write_exp_elt_longcst (state, length);
	write_exp_elt_opcode (state, OP_AGGREGATE);
      }
      break;

    case OP_STRING:
      {
	write_exp_elt_opcode (state, OP_STRING);
	write_exp_string (state, operation->left.sval);
	write_exp_elt_opcode (state, OP_STRING);
      }
      break;

    default:
      gdb_assert (0);
    }
}



/* The parser as exposed to gdb.  */
int
rust_parse (struct parser_state *state)
{
  int result;
  struct cleanup *cleanup;

  obstack_init (&work_obstack);
  cleanup = make_cleanup_obstack_free (&work_obstack);
  rust_ast = NULL;

  pstate = state;
  result = rustparse ();

  if (!result)
    {
      const struct rust_op *ast = rust_ast;

      rust_ast = NULL;
      gdb_assert (ast);
      convert_ast_to_expression (state, ast, ast);
    }

  do_cleanups (cleanup);
  return result;
}

/* The parser error handler.  */
void
rusterror (char *msg)
{
  const char *where = prev_lexptr ? prev_lexptr : lexptr;
  error (_("A %s in expression, near `%s'."), (msg ? msg : "error"), where);
}



#define GDB_UNIT_TEST /* FIXME */
#ifdef GDB_UNIT_TEST

/* A test helper that lexes a string, expecting a single token.  It
   returns the lexer data for this token.  */
static RUSTSTYPE
rust_lex_test_one (const char *input, int expected)
{
  int token;
  RUSTSTYPE result;

  lexptr = input;
  paren_depth = 0;

  token = rustlex ();
  gdb_assert (token == expected);
  result = yylval;

  if (token)
    {
      token = rustlex ();
      gdb_assert (token == 0);
    }

  return result;
}

/* Test that INPUT lexes as the integer VALUE.  */
static void
rust_lex_int_test (const char *input, int value, int kind)
{
  RUSTSTYPE result = rust_lex_test_one (input, kind);
  gdb_assert (result.typed_val_int.val == value);
}

/* Test that INPUT lexes as the identifier, string, or byte-string
   VALUE.  KIND holds the expected token kind.  */
static void
rust_lex_stringish_test (const char *input, const char *value, int kind)
{
  RUSTSTYPE result = rust_lex_test_one (input, kind);
  gdb_assert (strcmp (result.sval.ptr, value) == 0);
}

/* Unit test the lexer.  */
static void
rust_lex_tests (void)
{
  int i;

  rust_lex_test_one ("", 0);
  rust_lex_test_one ("thread 23", 0);
  rust_lex_test_one ("task 23", 0);
  rust_lex_test_one ("th 104", 0);
  rust_lex_test_one ("ta 97", 0);

  /* FIXME check error cases */
  rust_lex_int_test ("'z'", 'z', INTEGER);
  rust_lex_int_test ("'\\xff'", 0xff, INTEGER);
  rust_lex_int_test ("'\\u{1016f}'", 0x1016f, INTEGER);
  rust_lex_int_test ("b'z'", 'z', INTEGER);
  rust_lex_int_test ("b'\\xfe'", 0xfe, INTEGER);

  rust_lex_int_test ("23", 23, DECIMAL_INTEGER);
  rust_lex_int_test ("2_344__29", 234429, INTEGER);
  rust_lex_int_test ("0x1f", 0x1f, INTEGER);
  rust_lex_int_test ("23usize", 23, INTEGER);
  rust_lex_int_test ("23i32", 23, INTEGER);
  rust_lex_int_test ("0x1_f", 0x1f, INTEGER);
  rust_lex_int_test ("0b1_101011__", 0x6b, INTEGER);
  rust_lex_int_test ("0o001177i64", 639, INTEGER);

  rust_lex_test_one ("23.", FLOAT);
  rust_lex_test_one ("23.99f32", FLOAT);
  rust_lex_test_one ("23e7", FLOAT);
  rust_lex_test_one ("23E-7", FLOAT);
  rust_lex_test_one ("23e+7", FLOAT);
  rust_lex_test_one ("23.99e+7f64", FLOAT);
  rust_lex_test_one ("23.82f32", FLOAT);

  rust_lex_stringish_test ("hibob", "hibob", IDENT);
  rust_lex_stringish_test ("hibob__93", "hibob__93", IDENT);
  rust_lex_stringish_test ("thread", "thread", IDENT);

  rust_lex_stringish_test ("\"string\"", "string", STRING);
  rust_lex_stringish_test ("\"str\\ting\"", "str\ting", STRING);
  rust_lex_stringish_test ("\"str\\\"ing\"", "str\"ing", STRING);
  rust_lex_stringish_test ("r\"str\\ing\"", "str\\ing", STRING);
  rust_lex_stringish_test ("r#\"str\\ting\"#", "str\\ting", STRING);
  rust_lex_stringish_test ("r###\"str\\\"ing\"###", "str\\\"ing", STRING);

  rust_lex_stringish_test ("b\"string\"", "string", BYTESTRING);
  rust_lex_stringish_test ("b\"\x73tring\"", "string", BYTESTRING);
  rust_lex_stringish_test ("b\"str\\\"ing\"", "str\"ing", BYTESTRING);
  rust_lex_stringish_test ("br####\"\\x73tring\"####", "\\x73tring",
			   BYTESTRING);

  for (i = 0; i < ARRAY_SIZE (identifier_tokens); ++i)
    rust_lex_test_one (identifier_tokens[i].name, identifier_tokens[i].value);

  for (i = 0; i < ARRAY_SIZE (operator_tokens); ++i)
    rust_lex_test_one (operator_tokens[i].name, operator_tokens[i].value);
}

#endif

void
_initialize_rust_exp (void)
{
  int code = regcomp (&number_regex, number_regex_text, REG_EXTENDED);
  if (code != 0)
    {
      char *err = get_regcomp_error (code, &number_regex);

      make_cleanup (xfree, err);
      error (_("_initialize_rust_exp: could not compile regex: %s"), err);
    }

  /* It would be great if gdb had a "maint selftest" command; modules
     could register unit test functions and this command would simply
     invoke them, barfing on exceptions or checking return
     results.  */
#ifdef GDB_UNIT_TEST
  obstack_init (&work_obstack);
  unit_testing = 1;
  rust_lex_tests ();
  obstack_free (&work_obstack, NULL);
  unit_testing = 0;
#endif
}
