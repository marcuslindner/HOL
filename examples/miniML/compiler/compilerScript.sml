open HolKernel bossLib pairLib MiniMLTheory listTheory bytecodeTheory lcsymtacs

val _ = new_theory "compiler"

val _ = Hol_datatype`
  compiler_state =
  <|
   (* inl is stack variable
      inr is environment (heap) variables:
        (location of block on stack, location of variable in block) *)
    env: (varN,num+(num # num)) env
  ; next_label: num
  ; inst_length: bc_inst -> num
  |>`

val compile_lit_def = Define`
  (compile_lit (IntLit  n) = PushInt n)
∧ (compile_lit (Bool b) = PushInt (bool2num b))`;

val compile_val_def = tDefine "compile_val"`
  (compile_val (Lit l) = [Stack (compile_lit l)])
∧ (compile_val (Conv NONE ((Lit (IntLit c))::vs)) =
   let n  = LENGTH vs in
   if n = 0 then [Stack (PushInt c)] else
   let vs = FLAT (MAP compile_val vs) in
   SNOC (Stack (Cons (Num c) n)) vs)
(* literals and desugared constructors only *)`
(WF_REL_TAC `measure v_size` >>
 Induct >>
 srw_tac [][] >>
 fsrw_tac [ARITH_ss][exp_size_def,LENGTH_NIL] >>
 res_tac >> Cases_on `vs=[]` >> fsrw_tac [][] >>
 DECIDE_TAC)

val compile_opn_def = Define`
  (compile_opn Plus   = [Stack Add])
∧ (compile_opn Minus  = [Stack Sub])
∧ (compile_opn Times  = [Stack Mult])
 (* also want div2 and mod2 in ir, to compile to those when possible *)
∧ (compile_opn Divide = []) (* TODO *)
∧ (compile_opn Modulo = []) (* TODO *)`

val offset_def = Define`
  offset len xs = SUM (MAP len xs) + LENGTH xs`

val emit_def = Define`
  emit s ac is = (ac++is, s with next_label := s.next_label + offset s.inst_length is)`;

(* move elsewhere? *)
val exp1_size_thm = store_thm(
"exp1_size_thm",
``∀ls. exp1_size ls = SUM (MAP exp2_size ls) + LENGTH ls``,
Induct >- rw[exp_size_def] >>
qx_gen_tac `p` >>
PairCases_on `p` >>
srw_tac [ARITH_ss][exp_size_def])

val exp6_size_thm = store_thm(
"exp6_size_thm",
``∀ls. exp6_size ls = SUM (MAP exp7_size ls) + LENGTH ls``,
Induct >- rw[exp_size_def] >>
Cases >> srw_tac [ARITH_ss][exp_size_def])

val exp8_size_thm = store_thm(
"exp8_size_thm",
``∀ls. exp8_size ls = SUM (MAP exp_size ls) + LENGTH ls``,
Induct >- rw[exp_size_def] >>
srw_tac [ARITH_ss][exp_size_def])

(* move to listTheory? *)
val SUM_MAP_MEM_bound = store_thm(
"SUM_MAP_MEM_bound",
``∀f x ls. MEM x ls ⇒ f x ≤ SUM (MAP f ls)``,
ntac 2 gen_tac >> Induct >> rw[] >>
fsrw_tac [ARITH_ss][])

(* move elsewhere? *)
val fvs_def = tDefine "fvs"`
  (fvs (Var x) = {x})
∧ (fvs (Let x _ b) = fvs b DELETE x)
∧ (fvs (Letrec ls b) = FOLDL (λs (n,x,b). s ∪ (fvs b DELETE x))
                             (fvs b DIFF (FOLDL (combin$C ($INSERT o FST)) {} ls))
                             ls)
∧ (fvs (Fun x b) = fvs b DELETE x)
∧ (fvs (App _ e1 e2) = fvs e1 ∪ fvs e2)
∧ (fvs (Log _ e1 e2) = fvs e1 ∪ fvs e2)
∧ (fvs (If e1 e2 e3) = fvs e1 ∪ fvs e2 ∪ fvs e3)
∧ (fvs (Mat e pes) = fvs e ∪ FOLDL (λs (p,e). s ∪ fvs e) {} pes)
∧ (fvs (Proj e _) = fvs e)
∧ (fvs (Raise _) = {})
∧ (fvs (Val _) = {})
∧ (fvs (Con _ es) = FOLDL (λs e. s ∪ fvs e) {} es)`
(WF_REL_TAC `measure exp_size` >>
srw_tac [ARITH_ss][exp1_size_thm,exp6_size_thm,exp8_size_thm] >>
imp_res_tac SUM_MAP_MEM_bound >|
  map (fn q => pop_assum (qspec_then q mp_tac))
  [`exp2_size`,`exp7_size`,`exp_size`] >>
srw_tac[ARITH_ss][exp_size_def])

(* compile : exp * compiler_state → bc_inst list * compiler_state *)
val compile_def = Define`
  (compile (Raise err, s) = ARB) (* TODO *)
∧ (compile (Val v, s) = emit s [] (compile_val v))
∧ (compile (Mat e pes, s) = ARB) (* TODO *)
∧ (compile (Con NONE [c], s) = ARB) (* TODO *)
∧ (compile (Con NONE (c::es), s) = ARB) (* TODO *)
∧ (compile (Con (SOME _) _, s) = ARB) (* Disallowed; use remove_ctors *)
∧ (compile (Proj e n, s) = ARB) (* TODO *)
∧ (compile (Let x e b, s) =
   let (e,s) = compile (e,s) in
   let n = LENGTH s.env in
   let s' = s with env := bind x (INL n) s.env in  (* TODO: track size separately? *)
   let (b,s') = compile (b,s') in
   let (r,s') = emit s' (e++b) [Stack (Store 0)] in (* replace value of bound var with value of body *)
   (r, s' with env := s.env))
∧ (compile (Letrec defs b, s) = ARB) (* TODO *)
∧ (compile (Var x, s) =
   case lookup x s.env of
     NONE => ARB (* should not happen *)
   | SOME (INL n) => emit s [] [Stack (Load (LENGTH s.env - n))]
   | SOME (INR (n,m)) => emit s [] [Stack (Load (LENGTH s.env - n)); Stack (El m)])
∧ (compile (Fun x b, s) =
   (*  Load ?                               stack:
       ...      (* set up environment *)
       Cons 0 ?                             Cons 0 Env, rest
       Call L                               Cons 0 Env, CodePtr f, rest
       ?
       ...      (* function body *)
       Store 0  (* replace argument with
                   return value *)
       Return
    L: Cons 0 2 (* create closure *)        Cons 0 [CodePtr f, Cons 0 Env], rest
  *)
   let (r,s) = emit s [] [Stack (Cons 0 0) ] in (* TODO: find free variables in b,
                                                         copy values into a block *)
   let s' = s with env := ARB (* TODO: create inr bindings for each, with the environment at position 0
                                       create a dummy binding for the return pointer,
                                       create an inl binding for the argument at position 2 *)
                              in
   let (aa,s) = emit s [] [Call ARB] in
   let (b,s') = compile (b,s') in
   let (b,s') = emit s' b [Stack (Store 0);Return] in
   let s = s' with env := s.env in
   let l = s.next_label in
   let (b,s) = emit s b [Stack (Cons 0 2)] in
     (r++[Call l]++b,s))
∧ (compile (App Opapp e1 e2, s) =
   let (e1,s) = compile (e1,s) in  (* A closure looks like Cons 0 [CodePtr code; Cons 0 Env] *)
   let (e2,s) = compile (e2,s) in
   let (r,s) = emit s (e1++e2) [Stack (Load 1); Stack (El 1)] in (* stack after: env, arg, closure, rest *)
   let (r,s) = emit s r [Stack (Load 2); Stack (El 0)] in (* stack after: codeptr, env, arg, closure, rest *)
   let (r,s) = emit s r [Stack (Load 1); Stack (Store 3); Stack (Pops 1)] in (* stack after: codeptr, arg, env, rest *)
   let (r,s) = emit s r [CallPtr] in (* stack after: arg, return ptr, env, rest *)
     (r,s))
∧ (compile (App Equality e1 e2, s) =
 (* want type info? *)
 (* TODO: currently this is pointer equality, but want structural? *)
   let (e1,s) = compile (e1,s) in
   let (e2,s) = compile (e2,s) in
   emit s (e1++e2) [Stack Equal])
∧ (compile (App (Opn op) e1 e2, s)
  = let (e1,s) = compile (e1,s) in
    let (e2,s) = compile (e2,s) in
    emit s (e1++e2) (compile_opn op))
∧ (compile (App (Opb Lt) e1 e2, s)
  = let (e1,s) = compile (e1,s) in
    let (e2,s) = compile (e2,s) in
    emit s (e1++e2) [Stack Less])
∧ (compile (App (Opb Geq) e1 e2, s)
  = let (e2,s) = compile (e2,s) in
    let (e1,s) = compile (e1,s) in
    emit s (e2++e1) [Stack Less])
∧ (compile (App (Opb Gt) e1 e2, s)
  = let (e0,s) = emit s [] [Stack (PushInt 0)] in
    let (e1,s) = compile (e1,s) in
    let (e2,s) = compile (e2,s) in
    emit s (e0++e1++e2) [Stack Sub;Stack Less])
∧ (compile (App (Opb Leq) e1 e2, s)
  = let (e0,s) = emit s [] [Stack (PushInt 0)] in
    let (e2,s) = compile (e2,s) in
    let (e1,s) = compile (e1,s) in
    emit s (e0++e2++e1) [Stack Sub;Stack Less])
∧ (compile (Log And e1 e2, s)
  = let (e1,s) = compile (e1,s) in
    let (aa,s) = emit s ARB [JumpNil ARB] in
    let (e2,s) = compile (e2,s) in
    (e1++[JumpNil s.next_label]++e2, s))
∧ (compile (Log Or e1 e2, s)
  = let (e1,s) = compile (e1,s) in
    let f n1 n2 = [JumpNil n1;Stack (PushInt (bool2num T));Jump n2] in
    let (aa,s) = emit s ARB (f ARB ARB) in
    let n1     = s.next_label in
    let (e2,s) = compile (e2,s) in
    let n2     = s.next_label in
    (e1++(f n1 n2)++e2, s))
∧ (compile (If e1 e2 e3, s)
  = let (e1,s) = compile (e1,s) in
    let f n1 n2 = [JumpNil n1;Jump n2] in
    let (aa,s) = emit s ARB (f ARB ARB) in
    let n1     = s.next_label in
    let (e2,s) = compile (e2,s) in
    let (aa,s) = emit s ARB [Jump ARB] in
    let n2     = s.next_label in
    let (e3,s) = compile (e3,s) in
    let n3     = s.next_label in
    (e1++(f n1 n2)++e2++[Jump n3]++e3, s))`

val _ = export_theory ()
