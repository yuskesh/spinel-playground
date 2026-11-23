/* test/btf/fixtures/kbtf_fixture.c — kernel の BTF の reader の差動の種 (E004): flavor の名前 (___)・bitfield・enum64・decl tag・
 * type tag・入れ子の typedef・匿名の member・6 つ以上の member・同じ名前の異なる kind を持つ BTF。clang -g --target=bpf で .BTF に。 */
typedef unsigned long long u64;
typedef int s32;
typedef const volatile s32 cvs32;
typedef cvs32 cvs32_t;

struct thing { int a; long b; };
struct thing___v1 { int a; };
struct thing___v2 { long a; char c; };
struct ___lead { int x; };
struct a___b___c { int y; };
union thing___u { int a; long b; };
typedef struct thing thing;
enum big { BIG_A = 1, BIG_B = 0x100000000ULL };
enum small { SM_A = -1, SM_B = 2 };

struct bits {
	unsigned int f1 : 3;
	unsigned int f2 : 5;
	int f3 : 12;
	u64 f4 : 40;
	struct { int in1; int in2; };
	union { int un1; char un2; };
	char arr[4][3];
	void *p;
	int __attribute__((btf_type_tag("user"))) *up;
	int m7, m8;
};

struct __attribute__((btf_decl_tag("dtag"))) tagged {
	int x __attribute__((btf_decl_tag("mtag")));
};

int __attribute__((btf_decl_tag("ftag"))) tagged_fn(int a __attribute__((btf_decl_tag("ptag"))), struct bits *b)
{
	return a + b->f1;
}

static long long helper(cvs32_t x, thing *t, enum big e, enum small s, u64 v)
{
	return x + t->a + e + s + v;
}

long long use(struct thing___v1 *v1, struct thing___v2 *v2, union thing___u *u, struct ___lead *l, struct a___b___c *abc,
	      struct tagged *tg, float *f, double *d)
{
	return helper(1, 0, BIG_A, SM_A, 0) + v1->a + v2->c + u->a + l->x + abc->y + tg->x + (f != 0) + (d != 0);
}

struct fwd_only;
struct fwd_only *fwd_ptr(void) { return 0; }
