structure pairSimps :> pairSimps =
struct

open Lib Parse simpLib pairTheory PairedLambda;


(*------------------------------------------------------------------------
 * PAIR_ss
 *------------------------------------------------------------------------*)

val PAIR_ss = SIMPSET
  {convs=[{name="GEN_BETA_CONV (beta reduction)",
           trace=2,
           key=SOME ([],(--`(\(x,y):('a # 'b). y:'b) (z,w)`--)),
           conv=K (K GEN_BETA_CONV)},
	  {name = "let_CONV (reduction of let terms)",
	   trace = 2,
	   key = SOME ([], (--`$LET (f:'a->'b) x`--)),
	   conv = K (K let_CONV)}],
   rewrs = pairTheory.pair_rws @
           [CLOSED_PAIR_EQ, CURRY_UNCURRY_THM, UNCURRY_CURRY_THM,
            CURRY_ONE_ONE_THM, UNCURRY_ONE_ONE_THM,CURRY_DEF,
            PAIR_MAP_THM, UNCURRY_DEF],
   filter=NONE,ac=[],dprocs=[],congs=[]};

val _ = BasicProvers.augment_srw_ss [PAIR_ss];

end (* struct *)
