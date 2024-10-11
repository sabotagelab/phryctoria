# Phryctoria
Code used for the paper "Decentralized Predicate Detection over Partially Synchronous Continuous-Time Signals".

Steps to run a simple example with signals in the `signals` directory, a conjunctive predicate of $x_1 \geq 0 \land x_2 \geq 0 \land x_3 \geq 0$, and a max clock skew of 0.1:

1. Start Julia 1.8.2 in the src directory
2. `]activate .`
   (note the dot after activate! The closed bracket puts you in package mode)
3. `instantiate`
4. *\<backspace\>* `using phryctoria`
5. `startmonitor(3, .1)`

where 3 is the number of agents and .1 is the value of epsilon (max clock drift). You can change these of course.

The code currently only works with conjunctive predicates of the form $x_1 \geq 0 \land x_2 \geq 0 \land \dots$, so to use a different conjunctive predicate you will need to provide auxiliary signals which satisfy $x_1 \geq 0 \land x_2 \geq 0 \land \dots$ if and only if they satisfy your custom predicate.


![image](https://github.com/user-attachments/assets/cf5a09cb-9590-4480-a73f-95084adaefab)
