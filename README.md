# Phryctoria
Code used for the paper "Decentralized Predicate Detection over Partially Synchronous Continuous-Time Signals".

Steps to run a simple example with signals in the `signals` directory, a conjunctive predicate of $x_1 \geq 0 \land x_2 \geq 0 \land x_3 \geq 0$, and a max clock skew of 0.1:

1. After starting Julia 1.8.2 in this directory: `]activate .`
2. `instantiate`
3. *\<backspace\>* `using phryctoria`
4. `startmonitor(3, .1)`

The code currently only works with conjunctive predicates of the form $x_1 \geq 0 \land x_2 \geq 0 \land \dots$, so to use a different conjunctive predicate you will need to provide auxiliary signals which satisfy $x_1 \geq 0 \land x_2 \geq 0 \land \dots$ if and only if they satisfy your custom predicate.
