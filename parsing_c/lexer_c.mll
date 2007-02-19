{
open Common open Commonop

open Parser_c
open Lexer_parser

open Ast_c (* to factorise tokens, OpAssign, ... *)

(*****************************************************************************)
(*
 * todo?: stdC: multibyte character ??  
 *
 * subtil: ocamllex use side effect on lexbuf, so must take care. 
 * For instance must do   
 * 
 *  let info = tokinfo lexbuf in 
 *  TComment (info +> tok_add_s (comment lexbuf)) 
 * 
 * and not 
 * 
 *   TComment (tokinfo lexbuf +> tok_add_s (comment lexbuf)) 
 * 
 * because of the "wierd" order of evaluation of OCaml.
 *
 * note: can't use Lexer_parser._lexer_hint here to do different
 * things, because now we call the lexer to get all the tokens
 * (tokens_all), and then we parse. So we can't have the _lexer_hint
 * info here. We can have it only in parse_c. For the same reason, the
 * typedef handling here is now useless. 
 *)
(*****************************************************************************)

exception Lexical of string

let tok     lexbuf  = Lexing.lexeme lexbuf
let tokinfo lexbuf  = 
  { 
    Common.charpos = Lexing.lexeme_start lexbuf; 
    Common.str     = Lexing.lexeme lexbuf;
    line = -1; 
    column = -1; 
    file = "";
  }, ref Ast_c.emptyAnnot (* must generate a new ref each time, otherwise share*)

let tok_add_s s (info,annot) = {info with str = info.str ^ s}, annot
let tok_set s pos (info, annot) =  
  { info with 
    (* Common.charpos = pos; *)
    Common.str = s;
  }, annot
    

(* opti: less convenient, but using a hash is faster than using a match *)
let keyword_table = Common.hash_of_list [

  "void",   (fun ii -> Tvoid ii); 
  "char",   (fun ii -> Tchar ii);    
  "short",  (fun ii -> Tshort ii); 
  "int",    (fun ii -> Tint ii); 
  "long",   (fun ii -> Tlong ii); 
  "float",  (fun ii -> Tfloat ii); 
  "double", (fun ii -> Tdouble ii);  

  "unsigned", (fun ii -> Tunsigned ii);  
  "signed",   (fun ii -> Tsigned ii);
  
  "auto",     (fun ii -> Tauto ii);    
  "register", (fun ii -> Tregister ii);  
  "extern",   (fun ii -> Textern ii); 
  "static",   (fun ii -> Tstatic ii);

  "const",    (fun ii -> Tconst ii);
  "volatile", (fun ii -> Tvolatile ii); 
  
  "struct",  (fun ii -> Tstruct ii); 
  "union",   (fun ii -> Tunion ii); 
  "enum",    (fun ii -> Tenum ii);  
  "typedef", (fun ii -> Ttypedef ii);  
  
  "if",      (fun ii -> Tif ii);      
  "else",     (fun ii -> Telse ii); 
  "break",   (fun ii -> Tbreak ii);   
  "continue", (fun ii -> Tcontinue ii);
  "switch",  (fun ii -> Tswitch ii);  
  "case",     (fun ii -> Tcase ii);  
  "default", (fun ii -> Tdefault ii); 
  "for",     (fun ii -> Tfor ii);  
  "do",      (fun ii -> Tdo ii);      
  "while",   (fun ii -> Twhile ii);  
  "return",  (fun ii -> Treturn ii);
  "goto",    (fun ii -> Tgoto ii); 
  
  "sizeof", (fun ii -> Tsizeof ii);   

  (* gccext: *)
  "asm",     (fun ii -> Tasm ii);
  "__asm__", (fun ii -> Tasm ii);

  "inline",     (fun ii -> Tinline ii);
  "__inline__", (fun ii -> Tinline ii);
  "__inline",   (fun ii -> Tinline ii);
  "INLINE",     (fun ii -> Tinline ii); 
  "_INLINE_",   (fun ii -> Tinline ii); 

  "__attribute__", (fun ii -> Tattribute ii);
  "__const__",     (fun ii -> Tconst ii);

  "__volatile__",  (fun ii -> Tvolatile ii); 
  "__volatile",    (fun ii -> Tvolatile ii);  

  "STATIC",        (fun ii -> Tstatic ii); 
  "_static",       (fun ii -> Tstatic ii); 
 
  (* todo?  typeof, __typeof__  *)
  
 ]
}

(*****************************************************************************)
let letter = ['A'-'Z' 'a'-'z' '_']
let digit  = ['0'-'9']

(* not used for the moment *)
let punctuation = ['!' '"' '#' '%' '&' '\'' '(' ')' '*' '+' ',' '-' '.' '/' ':'
		   ';' '<' '=' '>' '?' '[' '\\' ']' '^' '{' '|' '}' '~']
let space = [' ' '\t' '\n' '\r' '\011' '\012' ]
let additionnal = [ ' ' '\b' '\t' '\011' '\n' '\r' '\007' ] 
(* 7 = \a = bell in C. this is not the only char allowed !! 
 * ex @ and $ ` are valid too 
 *)

let cchar = (letter | digit | punctuation | additionnal) 


let dec = ['0'-'9']
let oct = ['0'-'7']
let hex = ['0'-'9' 'a'-'f' 'A'-'F']

let decimal = ('0' | (['1'-'9'] dec*))
let octal   = ['0']        oct+
let hexa    = ("0x" |"0X") hex+ 


let pent   = dec+
let pfract = dec+
let sign = ['-' '+']
let exp  = ['e''E'] sign? dec+
let real = pent exp | ((pent? '.' pfract | pent '.' pfract? ) exp?)


(*****************************************************************************)
rule token = parse

  (* ----------------------------------------------------------------------- *)
  (* spacing/comments *)
  (* ----------------------------------------------------------------------- *)
  | [' ' '\t' '\n' '\r' '\011' '\012' ]+  
      { TCommentSpace (tokinfo lexbuf) }
  | "/*" 
      { let i = tokinfo lexbuf in TComment(i +> tok_add_s (comment lexbuf))}


  (* ----------------------------------------------------------------------- *)
  (* cpp part 1 *)
  (* ----------------------------------------------------------------------- *)

  (* old:
   *   | '#'		{ endline lexbuf} // should be line, and not endline 
   *   and endline = parse  | '\n' 	{ token lexbuf}  
   *                        |	_	{ endline lexbuf} 
   *)
      
  (* C++ comment, allowed in gccext,  but normally they are deleted by cpp.
   * So need this here only when dont call cpp before.  *)
  | "//" [^'\r''\n' '\011']*    { TComment (tokinfo lexbuf) } 

  | "#pragma pack"               [^'\n']* '\n'  
  | "#pragma GCC set_debug_pwd " [^'\n']* '\n'  
  | "#pragma alloc_text"         [^'\n']* '\n'  
      { TCommentCpp (tokinfo lexbuf) }

  | "#" [' ' '\t']* "ident"   [' ' '\t']+  [^'\n']+ '\n' 
      { TCommentCpp (tokinfo lexbuf) }

  | "#" [' ' '\t']* "error"   [' ' '\t']+  [^'\n']* '\n' 
  | "#" [' ' '\t']* "warning" [' ' '\t']+  [^'\n']* '\n'                     
  | "#" [' ' '\t']* "abort"   [' ' '\t']+  [^'\n']* '\n'
      { TCommentCpp (tokinfo lexbuf) }

  (* in drivers/char/tpqic02.c *)
  | "#" [' ' '\t']* "error"  { TCommentCpp (tokinfo lexbuf)} 


  (* todo?:
   *  have found a # #else  in "newfile-2.6.c",  legal ?   and also a  #/* ... 
   *    => just "#" -> token {lexbuf} (that is ignore)
   *  y'a 1 #elif  sans rien  apres
   *  y'a 1 #error sans rien  apres
   *  y'a 2  mov dede, #xxx    qui genere du coup exn car entour� par des #if 0
   *  => make as for comment, call a comment_cpp that when #endif finish the
   *   comment and if other cpp stuff raise exn
   *  y'a =~10  #if(xxx)  ou le ( est coll� direct
   *  y'a des include"" et include<
   *  y'a 1 ` (derriere un #ifndef linux)
   *)

  | ( ("#" [' ' '\t']*  "define" [' ' '\t']+) as s1)
    ( (letter (letter |digit)*) as ident) 
    { 
      let i1 = tokinfo lexbuf in 
      let pos = (fst i1).charpos in
      let bodys = cpp_eat_until_nl lexbuf in
      TDefine (ident, bodys, 
              tok_set s1 pos i1, 
              tok_set ident (pos + String.length s1)  (Ast_c.fakeInfo ()), 
              tok_set bodys (pos + String.length (s1 ^ ident)) 
                (Ast_c.fakeInfo ())
      )
    }

  (* todo: consider differently macro with arguments ? *)
  | ( ("#" [' ' '\t']*  "define" [' ' '\t']+) as s1)
    ( (letter (letter |digit)*) as ident) 
    ( ('(' [^ ')']* ')' ) as startbody) { 
      let i1 = tokinfo lexbuf in 
      let pos = (fst i1).charpos in
      let bodys = cpp_eat_until_nl lexbuf in
      TDefine (ident, bodys, 
              tok_set s1 pos i1, 
              tok_set ident (pos + String.length s1) (Ast_c.fakeInfo()), 
              tok_set (startbody ^ bodys) (pos + String.length (s1 ^ ident))
                                                (Ast_c.fakeInfo())
      )
    }

  | "#" [' ' '\t']* "undef" [' ' '\t']+ (letter (letter |digit)*) [' ''\t''\n']
      { TCommentCpp (tokinfo lexbuf) }


  | (("#" [' ''\t']* "include" [' ' '\t']*) as s1) 
    (('"' ([^ '"']+) '"' | 
     '<' [^ '>']+ '>' | 
      ['A'-'Z''_']+ 
    ) as filename)
      {
        let i1 = tokinfo lexbuf in 
        let pos = (fst i1).charpos in
        TInclude (filename, 
                 tok_set s1 pos i1, 
                 tok_set filename (pos + String.length s1) (Ast_c.fakeInfo())
        )
      }

   (* special_for_no_exn: in atm/ambassador.c *)
  | "#include UCODE(" [^'\n']+  '\n'    { TCommentCpp (tokinfo lexbuf) }


  | "#" [' ' '\t']* "if" [' ' '\t']* '0'+   [^'\n']*  '\n'
      { let info = tokinfo lexbuf in 
        let x = cpp_comment_if_0 lexbuf in
        TCommentCpp (info +> tok_add_s x) 
      }

  (* can have some ifdef 0  hence the letter|digit even at beginning of word *)
  | "#" [' ''\t']* "ifdef"  [' ''\t']+ (letter|digit) ((letter|digit)*) [' ''\t']*  
      { TIfdef (tokinfo lexbuf) }
  | "#" [' ''\t']* "ifndef" [' ''\t']+ (letter|digit) ((letter|digit)*) [' ''\t']*  
      { TIfdef (tokinfo lexbuf) }
  | "#" [' ''\t']* "if" [' ' '\t']+                                           
      { let info = tokinfo lexbuf in 
        TIfdef (info +> tok_add_s (cpp_eat_until_nl lexbuf)) 
      }
  | "#" [' ' '\t']* "if" '('                
      { let info = tokinfo lexbuf in 
        TIfdef (info +> tok_add_s (cpp_eat_until_nl lexbuf))
      }

  | "#" [' ' '\t']* "elif" [' ' '\t']+ [^'\n']+ '\n' 
      { TIfdefelif (tokinfo lexbuf) }

  (* can have #endif LINUX *)
  | "#" [' ' '\t']* "endif" [^'\n']* '\n'    { TEndif     (tokinfo lexbuf) }
  (* can be at eof *)
  | "#" [' ' '\t']* "endif"                  { TEndif     (tokinfo lexbuf) }


  | "#" [' ' '\t']* "else" [' ' '\t' '\n']   { TIfdefelse (tokinfo lexbuf) }
  (* there is a file in 2.6 that have this *)
  | "##" [' ' '\t']* "else" [' ' '\t' '\n'] { TIfdefelse (tokinfo lexbuf) }


  | "#" [' ' '\t']* '\n'                { TCommentCpp (tokinfo lexbuf) }

  | "\\" '\n' { TCommentSpace (tokinfo lexbuf) }
 
  (* ----------------------------------------------------------------------- *)
  (* C symbols *)
  (* ----------------------------------------------------------------------- *)
   (* stdC:
    ...   &&   -=   >=   ~   +   ;   ]    
    <<=   &=   ->   >>   %   ,   <   ^    
    >>=   *=   /=   ^=   &   -   =   {    
    !=    ++   <<   |=   (   .   >   |    
    %=    +=   <=   ||   )   /   ?   }    
        --   ==   !    *   :   [   
    recent addition:    <:  :>  <%  %> 
    only at processing: %:  %:%: # ##  
   *) 


  | '[' { TOCro(tokinfo lexbuf) }   | ']' { TCCro(tokinfo lexbuf) }
  | '(' { TOPar(tokinfo lexbuf)   } | ')' { TCPar(tokinfo lexbuf)   }
  | '{' { TOBrace(tokinfo lexbuf) } | '}' { TCBrace(tokinfo lexbuf) }

  | '+' { TPlus(tokinfo lexbuf) }   | '*' { TMul(tokinfo lexbuf) }     
  | '-' { TMinus(tokinfo lexbuf) }  | '/' { TDiv(tokinfo lexbuf) } 
  | '%' { TMod(tokinfo lexbuf) } 

  | "++"{ TInc(tokinfo lexbuf) }    | "--"{ TDec(tokinfo lexbuf) }

  | "="  { TEq(tokinfo lexbuf) } 

  | "-=" { TAssign (OpAssign Minus, (tokinfo lexbuf))} 
  | "+=" { TAssign (OpAssign Plus, (tokinfo lexbuf))} 
  | "*=" { TAssign (OpAssign Mul, (tokinfo lexbuf))}   
  | "/=" { TAssign (OpAssign Div, (tokinfo lexbuf))} 
  | "%=" { TAssign (OpAssign Mod, (tokinfo lexbuf))} 
  | "&=" { TAssign (OpAssign And, (tokinfo lexbuf))}  
  | "|=" { TAssign (OpAssign Or, (tokinfo lexbuf)) } 
  | "^=" { TAssign(OpAssign Xor, (tokinfo lexbuf))} 
  | "<<=" {TAssign (OpAssign DecLeft, (tokinfo lexbuf)) } 
  | ">>=" {TAssign (OpAssign DecRight, (tokinfo lexbuf))}

  | "==" { TEqEq(tokinfo lexbuf) }  | "!=" { TNotEq(tokinfo lexbuf) } 
  | ">=" { TInfEq(tokinfo lexbuf) } | "<=" { TSupEq(tokinfo lexbuf) } 
  | "<"  { TInf(tokinfo lexbuf) }   | ">"  { TSup(tokinfo lexbuf) }

  | "&&" { TAndLog(tokinfo lexbuf) } | "||" { TOrLog(tokinfo lexbuf) }
  | ">>" { TShr(tokinfo lexbuf) }    | "<<" { TShl(tokinfo lexbuf) }
  | "&"  { TAnd(tokinfo lexbuf) }    | "|" { TOr(tokinfo lexbuf) } 
  | "^" { TXor(tokinfo lexbuf) }
  | "..." { TEllipsis(tokinfo lexbuf) }
  | "->"   { TPtrOp(tokinfo lexbuf) }  | '.'  { TDot(tokinfo lexbuf) }  
  | ','    { TComma(tokinfo lexbuf) }  
  | ";"    { TPtVirg(tokinfo lexbuf) }
  | "?"    { TWhy(tokinfo lexbuf) }    | ":"   { TDotDot(tokinfo lexbuf) } 
  | "!"    { TBang(tokinfo lexbuf) }   | "~"   { TTilde(tokinfo lexbuf) }

  | "<:" { TOCro(tokinfo lexbuf) } | ":>" { TCCro(tokinfo lexbuf) } 
  | "<%" { TOBrace(tokinfo lexbuf) } | "%>" { TCBrace(tokinfo lexbuf) }
 



  | "ACPI_STATE_COMMON" { TCommentMisc (tokinfo lexbuf) }
  | "ACPI_PARSE_COMMON" { TCommentMisc (tokinfo lexbuf) }
  | "ACPI_COMMON_DEBUG_MEM_HEADER"  { TCommentMisc (tokinfo lexbuf) }

  | "TRACE_EXIT" {  Treturn (tokinfo lexbuf) } 

  | "static" [' ' '\t']+ ((['A'-'Z'] (['A'-'Z' '_'] | digit) *) as id)  [' ' '\t']* "(" [^'\n' ';']+ ';' [' ' '\t']* '\n' { 
        (match id with
        | "DECLARE_MUTEX" | "DECLARE_COMPLETION"  | "DECLARE_RWSEM"
        | "DECLARE_WAIT_QUEUE_HEAD" | "DEFINE_SPINLOCK"
        | "DEVICE_ATTR" | "CLASS_DEVICE_ATTR"  | "SENSOR_DEVICE_ATTR"
        | "LIST_HEAD"
        | "DECLARE_WORK"  | "DECLARE_TASKLET"
        | "PORT_ATTR_RO" | "PORT_PMA_ATTR"
          -> ()
        | s when s =~ "^DECLARE_.*" -> ()
        | s when s =~ ".*_ATTR$" -> ()
        | s when s =~ "^DEFINE_.*" -> ()

        | _ -> pr2 ("LEXER: PassingMacro: " ^ id)
        ); 
        TCommentMisc (tokinfo lexbuf) 
     }
   (* cos sometimes this one is on multiple line, so just transform it into an ident and then it looks like a funcall *)
   | "static" [' ' '\t']+ "DEVICE_ATTR" { TIdent (tok lexbuf, tokinfo lexbuf) }


  | "EXPORT_NO_SYMBOLS;" { TCommentMisc (tokinfo lexbuf) }

  (* normally can be handled,  but often the module_exist does not have a trailing ;  :(  *)
  | "module_exit(" letter (letter | digit)* ")"  
      { TCommentMisc (tokinfo lexbuf) }
  | "module_init(" letter (letter | digit)* ")"  
      { TCommentMisc (tokinfo lexbuf) }

  (*
    "DECLARE_TASKLET" 
  *)

  | "DECLARE_WAITQUEUE" [' ' '\t']* "(" [^'\n' ]+  '\n'       
      { TCommentMisc (tokinfo lexbuf) }
  | "DECLARE_COMPLETION" [' ' '\t']* "(" [^'\n']+ '\n'        
      { TCommentMisc (tokinfo lexbuf) }
  | "DECLARE_WAIT_QUEUE_HEAD" [' ' '\t']* "(" [^'\n' ]+  '\n' 
      { TCommentMisc (tokinfo lexbuf) }
  | "DECLARE_COMPLETION" [' ' '\t']* "(" [^'\n']+ '\n'        
      { TCommentMisc (tokinfo lexbuf) }







 (* struct def component. todo? generalize via LALR(k) tech by using a
  *  "in_struct"  context_info.
  *)
  | "ACPI_COMMON_OBJ_INFO;"                 
      { TCommentMisc (tokinfo lexbuf) }
  | "CS_OWNER" [' ' '\t']+ "CS_THIS_MODULE" 
      { TCommentMisc (tokinfo lexbuf) }

 (* misc *)
  | "__MODULE_STRING" '(' [^ ')']* ')'               
      { TCommentMisc (tokinfo lexbuf) }
  | "ACPI_MODULE_NAME" [' ' '\t']* "(" [^'\n']+ '\n' 
      { TCommentMisc (tokinfo lexbuf) }

 (* common macro of device driver *)
 | "I2C_CLIENT_INSMOD;"   { TCommentMisc (tokinfo lexbuf) }




  (* ----------------------------------------------------------------------- *)
  (* C keywords and ident *)
  (* ----------------------------------------------------------------------- *)

  | letter (letter | digit) *  { 
      
      (* StdC: must handle at least name of length > 509, but can
       * truncate to 31 when compare and truncate to 6 and even lowerise
       * in the external linkage phase *)
      let info = tokinfo lexbuf in
      let s = tok lexbuf in
      Common.profile_code "C parsing.lex_ident" (fun () -> 
        match Common.optionise (fun () -> Hashtbl.find keyword_table s)
        with
        | Some f -> f info
        | None -> TIdent (s, info)
      )            
      (*
        (match s with
        | s when s =~ "__.*__" -> TCommentAttrOrMacro info
        | s -> 
            if s =~ "_.*" then 
            warning "_ is often reserved for internal use by the compiler" ^
                    "and libc\n" ()
            * parse_typedef_fix. note: now this is no more useful,
            * cos as we use tokens_all, it first parse all as an
            * ident and later transform an indent in a typedef. so
            * this job is now done in parse_c.ml

	    if Lexer_parser.is_typedef s 
            then TypedefIdent (s, info)
            else TIdent (s, info)
       *)
    }	

  (* ----------------------------------------------------------------------- *)
  (* C constant *)
  (* ----------------------------------------------------------------------- *)

  | "'"     
      { let info = tokinfo lexbuf in 
      let s = char lexbuf   in 
      TChar     ((s,   IsChar),  (info +> tok_add_s (s ^ "'"))) 
      }
  | '"'     
      { let info = tokinfo lexbuf in
      let s = string lexbuf in 
      TString   ((s,   IsChar),  (info +> tok_add_s (s ^ "\""))) 
      }
  (* wide character encoding, TODO L'toto' valid ? what is allowed ? *)
  | 'L' "'" 
      { let info = tokinfo lexbuf in 
      let s = char lexbuf   in 
      TChar     ((s,   IsWchar),  (info +> tok_add_s (s ^ "'"))) 
      } 
  | 'L' '"' 
      { let info = tokinfo lexbuf in 
      let s = string lexbuf in 
      TString   ((s,   IsWchar),  (info +> tok_add_s (s ^ "\""))) 
      }


  (* take care of the order ? no cos lex try the longest match the
   * strange diff between decimal and octal constant semantic is not
   * understood too by refman :) refman:11.1.4, and ritchie 
   *)

  | (( decimal | hexa | octal) 
        ( ['u' 'U'] 
        | ['l' 'L']  
        | (['l' 'L'] ['u' 'U'])
        | (['u' 'U'] ['l' 'L'])
        | (['u' 'U'] ['l' 'L'] ['l' 'L'])
        | (['l' 'L'] ['l' 'L'])
        )?
    ) as x { TInt (x, tokinfo lexbuf) }


  | (real ['f' 'F']) as x { TFloat ((x, CFloat),      tokinfo lexbuf) }
  | (real ['l' 'L']) as x { TFloat ((x, CLongDouble), tokinfo lexbuf) }
  | (real as x)           { TFloat ((x, CDouble),     tokinfo lexbuf) }

  | ['0'] ['0'-'9']+  
      { raise 
          (Lexical "numeric octal constant contains digits beyond the radix") 
      }
  | ("0x" |"0X") ['0'-'9' 'a'-'z' 'A'-'Z']+ 
      { 
        (* special_for_no_exn: *)
        pr2 "LEXER: numeric hexa constant contains digits beyond the radix";
        TCommentMisc (tokinfo lexbuf)
        (* raise (Lexical "numeric hexa constant contains digits beyond the radix") *)
      }


 (* special, !!! to put after other rules such  !! otherwise 0xff
  * will be parsed as an ident  
  *)
  | ['0'-'9']+ letter (letter | digit) *  { 
       let info = tokinfo lexbuf in
       pr2 ("LEXER: ZARB integer_string, certainly a macro:" ^ (fst info).str);
       TIdent (tok lexbuf, info)
     } 

(*  | ['0'-'1']+'b' { TInt (((tok lexbuf)<!!>(0,-2)) +> int_of_stringbits) } *)


  (*------------------------------------------------------------------------ *)
  | eof { let (w,an) = tokinfo lexbuf in EOF ({w with Common.str = ""},an) }

  | _ { raise (Lexical ("unrecognised symbol, in token rule:"^tok lexbuf)) }



(*****************************************************************************)
and char = parse
  | (_ as x)                                    "'"  { String.make 1 x }
  (* todo?: as for octal, do exception  beyond radix exception ? *)
  | (("\\" (oct | oct oct | oct oct oct)) as x  "'") { x }  
  (* this rule must be after the one with octal, lex try first longest
   * and when \7  we want an octal, not an exn 
   *)
  | (("\\x" ((hex | hex hex))) as x        "'") { x }
  | (("\\" (_ as v)) as x                       "'")
	{ 
          (match v with (* Machine specific ? *)
          | 'n' -> ()  | 't' -> ()   | 'v' -> ()  | 'b' -> () | 'r' -> ()  
          | 'f' -> () | 'a' -> ()
	  | '\\' -> () | '?'  -> () | '\'' -> ()  | '"' -> ()
          | 'e' -> () (* linuxext: ? *)
	  | _ -> raise (Lexical ("unrecognised symbol:"^tok lexbuf))
	  );
          x
	} 
  (* toreput?: trigraph, cf less/ *)
  | _ { raise (Lexical ("unrecognised symbol:"^tok lexbuf)) }




(*****************************************************************************)
(* todo: factorise code with char *)
and string  = parse
  | '"'                                       { "" }
  | (_ as x)                                  { string_of_char x^string lexbuf}
  | ("\\" (oct | oct oct | oct oct oct)) as x { x ^ string lexbuf }
  | ("\\x" (hex | hex hex)) as x              { x ^ string lexbuf }
  | ("\\" (_ as v)) as x  
       { 
         (match v with (* Machine specific ? *)
         | 'n' -> ()  | 't' -> ()   | 'v' -> ()  | 'b' -> () | 'r' -> ()  
         | 'f' -> () | 'a' -> ()
	 | '\\' -> () | '?'  -> () | '\'' -> ()  | '"' -> ()
         | 'e' -> () (* linuxext: ? *)
         (*| "x" -> 10 (* gccext ? todo ugly, I put a fake value *)*)
         (* cppext:  can have   \ for multiline in string too *)
         | '\n' -> () 
         | _ -> raise (Lexical ("unrecognised symbol:"^tok lexbuf))
	 );
          x ^ string lexbuf
       }
 (* toreput?: trigraph, cf less/ *)

 (* bug if add that, cos match also the '"' that is needed
  *  to finish the string, and so go until end of file
  | [^ '\\']+ 
    { let cs = lexbuf +> tok +> list_of_string +> List.map Char.code in
    cs ++ string lexbuf  
    }
  *)
  | _ { raise (Lexical ("unrecognised symbol:"^tok lexbuf)) }




(*****************************************************************************)
(* todo?: allow only char-'*' *)
and comment = parse
  | "*/"     { tok lexbuf   }
  (* noteopti: *)
  | [^ '*']+ { let s = tok lexbuf in s ^ comment lexbuf }
  | [ '*']   { let s = tok lexbuf in s ^ comment lexbuf }
  | _        { raise (Lexical ("unrecognised symbol:"^tok lexbuf)) }



(*****************************************************************************)
(*
 * cpp recognize C comments, so when   #define xx (yy) /* comment \n ... */
 * then he has already erased the /* comment.
 * => dont eat the start of the comment and then get afterwards in the middle
 *  of a comment (and so a parse error).
 * => have to recognize comments in cpp_eat_until_nl.
*)


and cpp_eat_until_nl = parse
  | "/*"          
      { let s = tok lexbuf in 
        let s2 = comment lexbuf in 
        let s3 = cpp_eat_until_nl lexbuf in 
        s ^ s2 ^ s3  
      } (* fix *)
  | "\n"                          
      { tok lexbuf } 
  | '\\' "\n"                     
      { let s = tok lexbuf in s ^ cpp_eat_until_nl lexbuf }
  | [^ '\n' '\\'      '/' '*'  ]+ 
      { let s = tok lexbuf in s ^ cpp_eat_until_nl lexbuf } (* need fix too *)
  | eof 
      { raise (Lexical ("end of file in cpp_eat_until_nl" ^ tok lexbuf)) }
  | _                             
      { let s = tok lexbuf in s ^ cpp_eat_until_nl lexbuf }  



and cpp_comment_if_0 = parse
  | "#" [' ' '\t']* "endif" [^'\n']* '\n'    { tok lexbuf }

  | "#" [' ' '\t']* "else" [' ' '\t' '\n']    
  | "#" [' ' '\t']* "elif" [' ' '\t']+
   { 
     pr2 ("LEXER: GRAVE: #else with #if 0 badly handled, because final" ^
         "#endif will be alone") ;
     tok lexbuf
   }

 (* introduced cos sometimes there is some ifdef in comments inside stuff
  * inside a #if 0 
  *)
  | "//" [^'\r' '\n' '\011']*   
    { let s = tok lexbuf in s ^ cpp_comment_if_0 lexbuf }

  | "#" [' ' '\t']* "ifdef" [' ' '\t']+   
  | "#" [' ' '\t']* "ifndef"  [' ' '\t']+    
  | "#" [' ' '\t']* "if"  [' ' '\t']+       
    { 
      let s = tok lexbuf in 
      let s2 = cpp_until_endif lexbuf in
      let s3 = cpp_comment_if_0 lexbuf in
      s ^ s2 ^ s3
    }

 (* if you introduce new rule, dont forget to add the first symbol here,
  * otherwise the preceding rule will never fire, hidden by this gigantic
  * [^'#' '/']+
  *)
  (* noteopti: *) 
  | [^ '#' '/']+ { let s = tok lexbuf in s ^ cpp_comment_if_0 lexbuf }
  | [ '#']   { let s = tok lexbuf in s ^ cpp_comment_if_0 lexbuf }
  | [ '/']   { let s = tok lexbuf in s ^ cpp_comment_if_0 lexbuf }
  | _        { raise (Lexical ("unrecognised symbol:"^tok lexbuf)) }


and cpp_until_endif = parse
  | "#" [' ' '\t']* "endif" [^'\n']* '\n'  { tok lexbuf }

  | "#" [' ' '\t']* "ifdef" [' ' '\t']+   
  | "#" [' ' '\t']* "ifndef"  [' ' '\t']+    
  | "#" [' ' '\t']* "if"  [' ' '\t']+     
    {
     let s = tok lexbuf in 
     let s2 = cpp_until_endif lexbuf in
     let s3 = cpp_until_endif lexbuf in
     s ^ s2 ^ s3
     }
  (* noteopti: *)
  | [^ '#' ]+ { let s = tok lexbuf in s ^ cpp_until_endif lexbuf }
  | [ '#']    { let s = tok lexbuf in s ^ cpp_until_endif lexbuf }
  | _        { raise (Lexical ("unrecognised symbol:"^tok lexbuf)) }
    

