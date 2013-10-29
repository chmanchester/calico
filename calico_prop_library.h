#ifndef _calico_props
#define _calico_props

void multiply_int(int* a, int factor) {
  *a *= factor;
}

void multiply_int_array(int *a, int factor, int length) {
  int i;
  for (i = 0; i < length; i++) a[i] *= factor;
}

void multiply_double(double* a, double factor) {
  *a *= factor;
}

void multiply_double_array(double* a, double factor, double length) {
  int i;
  for (i = 0; i < length; i++) a[i] *= factor;
}

void id(void *a) {
  ;
}

#endif