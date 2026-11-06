import { useState, useMemo } from 'preact/hooks';
import { Fragment } from 'preact';
import { html } from '../router.js';
import { sortRows, nextDirection, ariaSort } from '../lib/sort.js';
import { fmtNum } from '../lib/format.js';

// The one table in the console. Every column header sorts (click for ascending,
// click again for descending) with a visible indicator and aria-sort, and the
// sort is applied to the whole `rows` array the caller passed — never to just
// the visible page, which would be a dishonest surface.
//
// columns: [{ key, label, sort?: row => value, cell: row => vnode, width?, align?, flex?, raw?, unit?, plain? }]
// A column with `sort: null` is explicitly unsortable (free-text log lines).
// `unit` (e.g. `$`, `min`, `%`) shows after the label. `raw` is the field or env
// name, shown small under the header so an operator can still grep for it; it
// sits outside the sort button so the button's name stays the plain label.
// A cell that returns a bare number is shown grouped (12,224, BH-9119); the sort
// still reads the raw value. `plain: true` shows the number as is (an id).
//
// `wide` opts the table out of the content-hugging default and into the page
// width, and `flex: true` on ONE column hands that column the space the
// content-sized columns leave over (styles.css, .tablewrap--wide). Only worth
// it where a row carries real prose — see IDEAS.
//
// `expand(row)` (optional) returns null, or { id, body } to put one full-width
// row directly under that row, wherever the sort moves it: a drill-down that
// opens in place (BH-5430, the merge queue's break-risk reasons). `id` is the
// expanded row's element id, so a #fragment can point at it.

const cellText = (col, row) => {
  const v = col.cell(row);
  return typeof v === 'number' && !col.plain ? fmtNum(v) : v;
};

export function SortableTable({ columns, rows, rowKey, rowClass, defaultSort, defaultDir = 'asc', empty, wide, expand }) {
  const [sortKey, setSortKey] = useState(defaultSort || columns[0].key);
  const [dir, setDir] = useState(defaultDir);

  const active = columns.find((c) => c.key === sortKey);
  const sorted = useMemo(() => {
    if (!active || active.sort === null) return rows;
    const accessor = active.sort || ((r) => r[active.key]);
    return sortRows(rows, accessor, dir);
  }, [rows, sortKey, dir, active]);

  const onHeader = (col) => {
    if (col.sort === null) return;
    setDir(nextDirection(col.key, sortKey, dir));
    setSortKey(col.key);
  };

  if (!rows.length && empty) return empty;

  return html`
    <div class=${wide ? 'tablewrap tablewrap--wide' : 'tablewrap'}>
      <table class="tbl">
        <thead>
          <tr>
            ${columns.map((col) => {
              const sortable = col.sort !== null;
              const sortState = sortable ? ariaSort(col.key, sortKey, dir) : undefined;
              const unit = col.unit ? html`<span class="th-unit">${col.unit}</span>` : null;
              const raw = col.raw ? html`<span class="th-raw">${col.raw}</span>` : null;
              return html`
                <th key=${col.key} aria-sort=${sortState} class=${col.flex ? 'col-flex' : ''}
                  style=${col.width ? `width:${col.width}` : ''}>
                  ${sortable
                    ? html`<button type="button" onClick=${() => onHeader(col)}
                        title=${`sort by ${col.label.toLowerCase()}`}>
                        ${col.label}${unit}
                        ${col.key === sortKey
                          ? html`<span class="arrow" aria-hidden="true">${dir === 'asc' ? '↑' : '↓'}</span>`
                          : null}
                      </button>`
                    : html`${col.label}${unit}`}
                  ${raw}
                </th>`;
            })}
          </tr>
        </thead>
        <tbody>
          ${sorted.map((row, i) => {
            const open = expand ? expand(row) : null;
            return html`<${Fragment} key=${rowKey ? rowKey(row) : i}>
            <tr class=${rowClass ? rowClass(row) : ''}>
              ${columns.map((col) => html`
                <td key=${col.key} class=${col.flex ? 'col-flex' : ''}
                  style=${col.align ? `text-align:${col.align}` : ''}>${cellText(col, row)}</td>`)}
            </tr>
            ${open ? html`<tr class="tbl-expand" id=${open.id}><td colspan=${columns.length}>${open.body}</td></tr>` : null}<//>`;
          })}
        </tbody>
      </table>
    </div>`;
}
