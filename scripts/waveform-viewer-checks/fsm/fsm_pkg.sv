package fsm_pkg;
  typedef enum logic [2:0] { IDLE, FETCH, DECODE = 3'd4, EXEC, DONE = 3'b111 } state_t;
endpackage
