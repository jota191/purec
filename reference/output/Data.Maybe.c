#include "Data.Maybe.h"

const purs_any_t _Data_Maybe_Nothing =
	{
		.tag = CONS,
		.value = {
			.cons = {
				.tag = Data_Maybe_Nothing__Tag
			}
		}
	};
const purs_any_t * Data_Maybe_Nothing = &_Data_Maybe_Nothing;

const purs_any_t * Data_Maybe_Just (purs_any_t * value0) {
	const purs_any_t ** values = GC_MALLOC(sizeof (purs_any_t*[1]));
	values[0] = value0;
	return purs_any_set_cons(
		GC_NEW(purs_any_t),
		(purs_cons_t) {
			.tag = Data_Maybe_Just__Tag,
			.len = 1,
			.values = values
		}
	);
}

const Data_Show_Show * Data_Maybe_showMaybe (const Data_Show_Show * dictShow) {
	Data_Show_Show * value0 = GC_NEW(Data_Show_Show);
	value0->show =
		PURS_ANY_BLOCK((const purs_any_t * x) {
				const purs_cons_t * value1 = purs_any_get_cons(x);
				if (value1->tag == Data_Maybe_Just__Tag) {
					return purs_any_concat(
						(const purs_any_t *) purs_any_set_string(
							GC_NEW(purs_any_t),
							managed_utf8str_new(afmt("(Just "))
						),
						purs_any_concat(
							purs_any_app(
								Data_Show_show(dictShow),
								value1->values[0]
							),
							(const purs_any_t *) purs_any_set_string(
								GC_NEW(purs_any_t),
								managed_utf8str_new(afmt(")"))
							)
						)
					);
				}

				if (value1->tag == Data_Maybe_Nothing__Tag) {
					return (const purs_any_t *) purs_any_set_string(
						GC_NEW(purs_any_t),
						managed_utf8str_new(afmt("(Nothing)"))
					);
				}

				/* failed pattern match */
				assert(0);
		});
	return value0;
}