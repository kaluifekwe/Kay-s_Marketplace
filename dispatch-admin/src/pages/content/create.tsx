import { Create, useForm } from "@refinedev/antd";
import { Form, Input, Select, InputNumber } from "antd";

const STATES = [
  "Abia", "Adamawa", "Akwa Ibom", "Anambra", "Bauchi", "Bayelsa", "Benue",
  "Borno", "Cross River", "Delta", "Ebonyi", "Edo", "Ekiti", "Enugu", "FCT",
  "Gombe", "Imo", "Jigawa", "Kaduna", "Kano", "Katsina", "Kebbi", "Kogi",
  "Kwara", "Lagos", "Nasarawa", "Niger", "Ogun", "Ondo", "Osun", "Oyo",
  "Plateau", "Rivers", "Sokoto", "Taraba", "Yobe", "Zamfara",
];

const CATEGORIES = ["buying-online", "selling-online", "safety", "delivery", "vendor-resources", "marketplace-trends"];

export const ContentCreate = () => {
  const { formProps, saveButtonProps } = useForm({
    resource: "content_items",
    redirect: "list",
  });

  return (
    <Create saveButtonProps={saveButtonProps} title="Add a research topic">
      <Form {...formProps} layout="vertical" initialValues={{ content_status: "DISCOVERED", priority: 0 }}>
        <Form.Item
          label="Topic"
          name="topic"
          rules={[{ required: true, message: "What's the real problem or question this covers?" }]}
        >
          <Input placeholder="e.g. Why didn't my order arrive on time?" />
        </Form.Item>

        <Form.Item label="Target keyword" name="keyword">
          <Input placeholder="e.g. why is my delivery late Lagos" />
        </Form.Item>

        <Form.Item label="Audience" name="audience" rules={[{ required: true }]}>
          <Select
            options={[
              { value: "buyer", label: "Buyer" },
              { value: "vendor", label: "Vendor" },
            ]}
          />
        </Form.Item>

        <Form.Item label="Search intent" name="search_intent">
          <Select
            allowClear
            options={[
              { value: "informational", label: "Informational (learning)" },
              { value: "commercial", label: "Commercial (comparing options)" },
              { value: "transactional", label: "Transactional (ready to buy)" },
              { value: "vendor", label: "Vendor (ready to sell)" },
            ]}
          />
        </Form.Item>

        <Form.Item label="Category" name="category">
          <Select allowClear showSearch options={CATEGORIES.map((c) => ({ value: c, label: c }))} />
        </Form.Item>

        <Form.Item label="State (if location-specific)" name="state">
          <Select allowClear showSearch options={STATES.map((s) => ({ value: s, label: s }))} />
        </Form.Item>

        <Form.Item label="Research summary" name="research_summary" extra="The real pain point, in your own words — this is what the draft gets written from.">
          <Input.TextArea rows={4} placeholder="What are Nigerians actually saying about this, and where did you see it?" />
        </Form.Item>

        <Form.Item label="Source" name="source" extra="e.g. 'google-search', 'manual-research'. Never a scraped platform name.">
          <Input placeholder="manual-research" />
        </Form.Item>

        <Form.Item label="Source URL (optional)" name="source_url">
          <Input placeholder="https://..." />
        </Form.Item>

        <Form.Item label="Priority" name="priority">
          <InputNumber min={0} max={100} style={{ width: 160 }} />
        </Form.Item>

        <Form.Item name="content_status" hidden>
          <Input />
        </Form.Item>
      </Form>
    </Create>
  );
};
