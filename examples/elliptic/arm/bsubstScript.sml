(* ========================================================================= *)
(* FILE          : bsubstScript.sml                                          *)
(* DESCRIPTION   : Block substitution and Memory Operations                  *)
(*                                                                           *)
(* AUTHOR        : (c) Anthony Fox, University of Cambridge                  *)
(* DATE          : 2005-2006                                                 *)
(* ========================================================================= *)

(* interactive use:
  app load ["wordsLib", "rich_listTheory", "my_listTheory"];
*)

open HolKernel boolLib bossLib;
open Parse Q arithmeticTheory wordsTheory;
open listTheory rich_listTheory my_listTheory;

val _ = new_theory "bsubst";

(* ------------------------------------------------------------------------- *)

infix \\ << >>

val op \\ = op THEN;
val op << = op THENL;
val op >> = op THEN1;

val _ = set_fixity ":-"   (Infixr 325);
val _ = set_fixity "::-"  (Infixr 325);
val _ = set_fixity "::->" (Infixr 325);
val _ = set_fixity "::-<" (Infixr 325);

val _ = computeLib.auto_import_definitions := false;

val SUBST_def = xDefine "SUBST" `$:- a b = \m c. if a = c then b else m c`;

val BSUBST_def = xDefine "BSUBST"
  `$::- a l = \m b.
      if a <=+ b /\ w2n b - w2n a < LENGTH l then
        EL (w2n b - w2n a) l
      else m b`;

val BSa_def = xDefine "BSa" `$::-> = $::-`;
val BSb_def = xDefine "BSb" `$::-< = $::-`;

val JOIN_def = Define`
  JOIN n x y =
    let lx = LENGTH x and ly = LENGTH y in
    let j = MIN n lx in
       GENLIST
         (\i. if i < n then
                if i < lx then EL i x else EL (i - j) y
              else
                if i - j < ly then EL (i - j) y else EL i x)
         (MAX (j + ly) lx)`;

val _ = computeLib.auto_import_definitions := true;

(* ------------------------------------------------------------------------- *)

val _ = Hol_datatype
  `formats = SignedByte | UnsignedByte
           | SignedHalfWord | UnsignedHalfWord
           | UnsignedWord`;

val _ = Hol_datatype
  `data = Byte of word8 | Half of word16 | Word of word32`;

val _ = type_abbrev("mem", ``:word30->word32``);

val GET_BYTE_def = Define`
  GET_BYTE (oareg:word2) (data:word32) =
    (case oareg of
        0w -> (7 >< 0) data
     || 1w -> (15 >< 8) data
     || 2w -> (23 >< 16) data
     || _  -> (31 >< 24) data):word8`;

val GET_HALF_def = Define`
  GET_HALF (oareg:word2) (data:word32) =
    (if oareg %% 1 then
       (31 >< 16) data
     else
       (15 >< 0) data):word16`;

val FORMAT_def = Define`
  FORMAT fmt oareg data =
    case fmt of
       SignedByte       -> sw2sw (GET_BYTE oareg data)
    || UnsignedByte     -> w2w (GET_BYTE oareg data)
    || SignedHalfWord   -> sw2sw (GET_HALF oareg data)
    || UnsignedHalfWord -> w2w (GET_HALF oareg data)
    || UnsignedWord     -> data #>> (8 * w2n oareg)`;

val SET_BYTE_def = Define`
  SET_BYTE (oareg:word2) (b:word8) (w:word32) =
    word_modify (\i x.
                  (i < 8) /\ (if oareg = 0w then b %% i else x) \/
       (8 <= i /\ i < 16) /\ (if oareg = 1w then b %% (i - 8) else x) \/
      (16 <= i /\ i < 24) /\ (if oareg = 2w then b %% (i - 16) else x) \/
      (24 <= i /\ i < 32) /\ (if oareg = 3w then b %% (i - 24) else x)) w`;

val SET_HALF_def = Define`
  SET_HALF (oareg:bool) (hw:word16) (w:word32) =
    word_modify (\i x.
                 (i < 16) /\ (if ~oareg then hw %% i else x) \/
      (16 <= i /\ i < 32) /\ (if oareg then hw %% (i - 16) else x)) w`;

val ADDR30_def = Define `ADDR30 (addr:word32) = (31 >< 2) addr:word30`;

val MEM_WRITE_BYTE_def = Define`
  MEM_WRITE_BYTE (mem:mem) addr (word:word8) =
    let addr30 = ADDR30 addr in
      (addr30 :- SET_BYTE ((1 >< 0) addr) word (mem addr30)) mem`;

val MEM_WRITE_HALF_def = Define`
  MEM_WRITE_HALF (mem:mem) addr (word:word16) =
    let addr30 = ADDR30 addr in
      (addr30 :- SET_HALF (addr %% 1) word (mem addr30)) mem`;

val MEM_WRITE_WORD_def = Define`
  MEM_WRITE_WORD (mem:mem) addr word = (ADDR30 addr :- word) mem`;

val MEM_WRITE_def = Define`
  MEM_WRITE mem addr d =
    case d of
       Byte b  -> MEM_WRITE_BYTE mem addr b
    || Half hw -> MEM_WRITE_HALF mem addr hw
    || Word w  -> MEM_WRITE_WORD mem addr w`;

val mem_read_def        = Define`mem_read (m: mem, a) = m a`;
val mem_write_def       = Define`mem_write (m:mem) a d = (a :- d) m`;
val mem_write_block_def = Define`mem_write_block (m:mem) a c = (a ::- c) m`;
val mem_items_def       = Define`mem_items (m:mem) = []:(word30 # word32) list`;
val empty_memory_def    = Define`empty_memory = (\a. 0xE6000010w):mem`;

(* ------------------------------------------------------------------------- *)

val JOIN_lem = prove(`!a b. MAX (SUC a) (SUC b) = SUC (MAX a b)`,
   RW_TAC std_ss [MAX_DEF]);

val JOIN_TAC =
  CONJ_TAC >> RW_TAC list_ss [LENGTH_GENLIST,MAX_DEF,MIN_DEF]
    \\ Cases
    \\ RW_TAC list_ss [MAX_DEF,MIN_DEF,LENGTH_GENLIST,EL_GENLIST,
         ADD_CLAUSES,HD_GENLIST]
    \\ FULL_SIMP_TAC arith_ss [NOT_LESS]
    \\ RW_TAC arith_ss [GENLIST,TL_SNOC,EL_SNOC,NULL_LENGTH,EL_GENLIST,
         LENGTH_TL,LENGTH_GENLIST,LENGTH_SNOC,(GSYM o CONJUNCT2) EL]
    \\ SIMP_TAC list_ss [];

val JOIN = store_thm("JOIN",
  `(!n ys. JOIN n [] ys = ys) /\
   (!xs. JOIN 0 xs [] = xs) /\
   (!x xs y ys. JOIN 0 (x::xs) (y::ys) = y :: JOIN 0 xs ys) /\
   (!n xs y ys. JOIN (SUC n) (x::xs) ys = x :: (JOIN n xs ys))`,
  RW_TAC (list_ss++boolSimps.LET_ss) [JOIN_def,JOIN_lem]
    \\ MATCH_MP_TAC LIST_EQ
    << [
      Cases_on `n` >> RW_TAC arith_ss [LENGTH_GENLIST,EL_GENLIST] \\ JOIN_TAC
        \\ `?p. LENGTH ys = SUC p` by METIS_TAC [ADD1,LESS_ADD_1,ADD_CLAUSES]
        \\ ASM_SIMP_TAC list_ss [HD_GENLIST],
      RW_TAC arith_ss [LENGTH_GENLIST,EL_GENLIST],
      JOIN_TAC, JOIN_TAC]);

(* ------------------------------------------------------------------------- *)

val BSUBST_EVAL = store_thm("BSUBST_EVAL",
  `!a b l m. (a ::- l) m b =
      let na = w2n a and nb = w2n b in
      let d = nb - na in
        if na <= nb /\ d < LENGTH l then EL d l else m b`,
  NTAC 2 wordsLib.Cases_word
    \\ RW_TAC (std_ss++boolSimps.LET_ss) [WORD_LS,BSUBST_def]
    \\ FULL_SIMP_TAC arith_ss []);

val SUBST_BSUBST = store_thm("SUBST_BSUBST",
   `!a b m. (a :- b) m = (a ::- [b]) m`,
  RW_TAC (std_ss++boolSimps.LET_ss) [FUN_EQ_THM,BSUBST_def,SUBST_def]
    \\ Cases_on `a = x`
    \\ ASM_SIMP_TAC list_ss [WORD_LOWER_EQ_REFL]
    \\ ASM_SIMP_TAC arith_ss [WORD_LOWER_OR_EQ,WORD_LO]);

val BSUBST_BSUBST = store_thm("BSUBST_BSUBST",
  `!a b x y m. (a ::- y) ((b ::- x) m) =
     let lx = LENGTH x and ly = LENGTH y in
        if a <=+ b then
          if w2n b - w2n a <= ly then
            if ly - (w2n b - w2n a) < lx then
              (a ::- y ++ BUTFIRSTN (ly - (w2n b - w2n a)) x) m
            else
              (a ::- y) m
          else
            (a ::- y) ((b ::- x) m)
        else (* b <+ a *)
          if w2n a - w2n b < lx then
            (b ::- JOIN (w2n a - w2n b) x y) m
          else
            (b ::- x) ((a ::- y) m)`,
  REPEAT STRIP_TAC \\ SIMP_TAC (bool_ss++boolSimps.LET_ss) []
    \\ Cases_on `a <=+ b`
    \\ FULL_SIMP_TAC std_ss [WORD_NOT_LOWER_EQUAL,WORD_LS,WORD_LO]
    << [
      Cases_on `w2n b <= w2n a + LENGTH y` \\ ASM_SIMP_TAC std_ss []
        \\ `w2n b - w2n a <= LENGTH y` by DECIDE_TAC
        \\ Cases_on `LENGTH x = 0`
        \\ Cases_on `LENGTH y = 0`
        \\ IMP_RES_TAC LENGTH_NIL
        \\ FULL_SIMP_TAC list_ss [FUN_EQ_THM,WORD_LS,BSUBST_def,BUTFIRSTN]
        >> (`w2n a = w2n b` by DECIDE_TAC \\ ASM_SIMP_TAC std_ss [])
        \\ NTAC 2 (RW_TAC std_ss [])
        \\ FULL_SIMP_TAC arith_ss
             [NOT_LESS,NOT_LESS_EQUAL,EL_APPEND1,EL_APPEND2,EL_BUTFIRSTN]
        \\ FULL_SIMP_TAC arith_ss []
        \\ `LENGTH y + w2n a - w2n b <= LENGTH x` by DECIDE_TAC
        \\ FULL_SIMP_TAC arith_ss [LENGTH_BUTFIRSTN],
      REWRITE_TAC [FUN_EQ_THM] \\ RW_TAC arith_ss []
        << [
          RW_TAC (arith_ss++boolSimps.LET_ss) [WORD_LS,BSUBST_def,JOIN_def,
                 EL_GENLIST,LENGTH_GENLIST,MIN_DEF,MAX_DEF]
            \\ FULL_SIMP_TAC arith_ss [],
          FULL_SIMP_TAC arith_ss [NOT_LESS]
            \\ IMP_RES_TAC LENGTH_NIL
            \\ RW_TAC (arith_ss++boolSimps.LET_ss) [WORD_LS,BSUBST_def]
            \\ FULL_SIMP_TAC arith_ss []]]);

(* ------------------------------------------------------------------------- *)

val RHS_REWRITE_RULE =
  GEN_REWRITE_RULE (DEPTH_CONV o RAND_CONV) empty_rewrites;

val defs_rule =
  BETA_RULE o PURE_REWRITE_RULE
    [GSYM n2w_itself_def, GSYM w2w_itself_def, GSYM sw2sw_itself_def,
     GSYM word_extract_itself_def,GSYM mem_write_def] o
  RHS_REWRITE_RULE [GSYM word_eq_def] o
  ONCE_REWRITE_RULE [GSYM mem_read_def];

val _ = ConstMapML.insert ``dimword``;
val _ = ConstMapML.insert ``dimindex``;
val _ = ConstMapML.insert ``INT_MIN``;
val _ = ConstMapML.insert ``n2w_itself``;

val _ = let open EmitML in emitML (!Globals.emitMLDir)
    ("bsubst", OPEN ["num", "fcp", "words"]
         :: MLSIG "type 'a word = 'a wordsML.word"
         :: MLSIG "type num = numML.num"
         :: MLSIG "type word2 = wordsML.word2"
         :: MLSIG "type word8 = wordsML.word8"
         :: MLSIG "type word16 = wordsML.word16"
         :: MLSIG "type word30 = wordsML.word30"
         :: MLSIG "type word32 = wordsML.word32"
         :: MLSTRUCT "type mem = word30->word32"
         :: MLSIG "type mem"
         :: MLSTRUCT "val mem_updates = ref ([]: word30 list)"
         :: MLSIG "val mem_updates : word30 list ref"
         :: DATATYPE (`formats = SignedByte | UnsignedByte
                               | SignedHalfWord | UnsignedHalfWord
                               | UnsignedWord`)
         :: DATATYPE (`data = Byte of word8 | Half of word16 | Word of word32`)
         :: map DEFN
              [SUBST_def, BSUBST_def, mem_read_def,
               mem_write_def,  mem_write_block_def]
          @ map (DEFN o defs_rule)
              [empty_memory_def, mem_items_def, ADDR30_def, GET_HALF_def,
               SIMP_RULE std_ss [literal_case_DEF] GET_BYTE_def,
               FORMAT_def, SET_BYTE_def, SET_HALF_def,
               MEM_WRITE_BYTE_def, MEM_WRITE_HALF_def,
               MEM_WRITE_WORD_def, MEM_WRITE_def])
end;

(* ------------------------------------------------------------------------- *)

val _ = export_theory();
