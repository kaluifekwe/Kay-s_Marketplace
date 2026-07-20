import { List, useTable, ShowButton, DateField } from "@refinedev/antd";
import { Table, Space, Tag, Input, Radio, Select } from "antd";
import { useEffect, useMemo, useState } from "react";
import type { CrudFilters } from "@refinedev/core";
import { supabaseClient } from "../../supabaseClient";

const roleColor: Record<string, string> = {
  admin: "purple",
  vendor: "geekblue",
  buyer: "green",
  rider: "orange",
};

// Buyers first: the larger group, and the view an operator opens most often.
type RoleTab = "buyer" | "vendor";

export const UserList = () => {
  const { tableProps, setFilters } = useTable({
    syncWithLocation: true,
    sorters: { initial: [{ field: "created_at", order: "desc" }] },
    filters: { initial: [{ field: "role", operator: "eq", value: "buyer" }] },
  });

  const [role, setRole] = useState<RoleTab>("buyer");
  const [stateFilter, setStateFilter] = useState<string | undefined>();
  const [q, setQ] = useState("");
  const [states, setStates] = useState<string[]>([]);

  // Populate the state dropdown from the values that actually exist, so it can
  // never offer a state that matches nothing. Stored values are inconsistent
  // ("Lagos", "Oyo", "FCT (Abuja)"), so a hardcoded list would silently miss
  // users.
  useEffect(() => {
    (async () => {
      const { data } = await supabaseClient
        .from("users")
        .select("state")
        .not("state", "is", null);
      const unique = Array.from(
        new Set(
          (data ?? [])
            .map((r: { state?: string }) => (r.state ?? "").trim())
            .filter(Boolean),
        ),
      ).sort();
      setStates(unique);
    })();
  }, []);

  // One place that composes the three controls into the filter set, so they
  // combine rather than overwrite each other.
  const apply = (nextRole: RoleTab, nextState: string | undefined, nextQ: string) => {
    const filters: CrudFilters = [{ field: "role", operator: "eq", value: nextRole }];
    if (nextState) filters.push({ field: "state", operator: "eq", value: nextState });
    if (nextQ.trim()) {
      filters.push({
        operator: "or",
        value: [
          { field: "name", operator: "contains", value: nextQ.trim() },
          { field: "email", operator: "contains", value: nextQ.trim() },
          { field: "phone", operator: "contains", value: nextQ.trim() },
        ],
      });
    }
    setFilters(filters, "replace");
  };

  const stateOptions = useMemo(
    () => [{ label: "All states", value: "" }, ...states.map((s) => ({ label: s, value: s }))],
    [states],
  );

  return (
    <List>
      <Space wrap style={{ marginBottom: 16 }}>
        <Radio.Group
          value={role}
          optionType="button"
          buttonStyle="solid"
          onChange={(e) => {
            const r = e.target.value as RoleTab;
            setRole(r);
            apply(r, stateFilter, q);
          }}
        >
          <Radio.Button value="buyer">Buyers</Radio.Button>
          <Radio.Button value="vendor">Vendors</Radio.Button>
        </Radio.Group>

        <Select
          style={{ minWidth: 180 }}
          placeholder="Filter by state"
          value={stateFilter ?? ""}
          options={stateOptions}
          onChange={(v) => {
            const s = v || undefined;
            setStateFilter(s);
            apply(role, s, q);
          }}
        />

        <Input.Search
          placeholder={`Search ${role === "buyer" ? "buyers" : "vendors"} by name, email or phone`}
          allowClear
          style={{ minWidth: 300 }}
          value={q}
          onChange={(e) => setQ(e.target.value)}
          onSearch={(value) => {
            setQ(value);
            apply(role, stateFilter, value);
          }}
        />
      </Space>

      <Table {...tableProps} rowKey="id">
        <Table.Column dataIndex="name" title="Name" />
        <Table.Column dataIndex="email" title="Email" />
        <Table.Column dataIndex="phone" title="Phone" render={(v: string) => v || "—"} />
        <Table.Column
          dataIndex="role"
          title="Role"
          render={(v: string) => <Tag color={roleColor[v] ?? "default"}>{v}</Tag>}
        />
        <Table.Column dataIndex="state" title="State" render={(v: string) => v || "—"} />
        <Table.Column
          dataIndex="created_at"
          title="Joined"
          render={(v) => (v ? <DateField value={v} format="YYYY-MM-DD" /> : "—")}
        />
        <Table.Column
          title="Actions"
          dataIndex="actions"
          render={(_, record: { id: string }) => (
            <Space>
              <ShowButton hideText size="small" recordItemId={record.id} />
            </Space>
          )}
        />
      </Table>
    </List>
  );
};
