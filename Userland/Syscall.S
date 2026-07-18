/*
 * Embedded Swift cannot emit SVC directly. Keep this veneer policy-free: it
 * only translates the scalar Swift call into the SwiftOS userspace syscall ABI.
 *
 *   Swift call: x0=number, x1=argument0, x2=argument1, x3=argument2
 *   SVC frame:  x8=number, x0=argument0, x1=argument1, x2=argument2
 *   return:     x0=result
 */

.section .text.swiftos.user.svc, "ax"
.align  2
.global swiftos_user_svc
.hidden swiftos_user_svc
.type   swiftos_user_svc, %function
swiftos_user_svc:
    mov     x8, x0
    mov     x0, x1
    mov     x1, x2
    mov     x2, x3
    svc     #0
    ret
.size swiftos_user_svc, . - swiftos_user_svc

.section .note.GNU-stack, "", %progbits
