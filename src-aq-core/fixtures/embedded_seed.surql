DEFINE TABLE person SCHEMALESS;
CREATE person:embedded SET name = 'embedded', source = 'embed-file';