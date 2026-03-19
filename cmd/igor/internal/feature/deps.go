package feature

// Resolve expands a set of explicitly selected feature IDs by following
// dependency chains (Requires) and implied-by rules. It returns a Selection
// with Explicit and Auto sets separated.
func Resolve(explicit map[string]bool, reg *Registry) *Selection {
	sel := &Selection{
		Explicit: make(map[string]bool),
		Auto:     make(map[string]bool),
	}

	for id := range explicit {
		sel.Explicit[id] = true
	}

	// Iteratively resolve until stable.
	changed := true
	for changed {
		changed = false
		all := sel.All()

		for id := range all {
			f := reg.Get(id)
			if f == nil {
				continue
			}

			// Follow Requires edges.
			for _, req := range f.Requires {
				if !sel.Has(req) {
					sel.Auto[req] = true
					changed = true
				}
			}
		}

		// Check ImpliedBy: if any feature in ImpliedBy is selected,
		// add the feature that declares it.
		for _, f := range reg.All() {
			if sel.Has(f.ID) {
				continue
			}
			for _, implier := range f.ImpliedBy {
				if sel.Has(implier) {
					sel.Auto[f.ID] = true
					changed = true
				}
			}
		}
	}

	return sel
}
