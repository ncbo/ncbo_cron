require 'ontologies_linked_data'
module Benchmarks

  def self.do_all_benchmarks(sub)
    Benchmarks.bench("fetch triples") do
      Benchmarks.paginate_all_triples(sub)
    end

    Benchmarks.bench("get ontology Concept Roots") do
      Benchmarks.ontology_roots(sub)
    end

    Benchmarks.bench("concept children") do
      Benchmarks.concept_children("http://terminologies.gfbio.org/ITIS/Taxa_0", sub)
    end

    Benchmarks.bench("concept path to root") do
      Benchmarks.concept_tree("http://terminologies.gfbio.org/ITIS/Taxa_6007", sub)
    end
  end

  def self.bench(label, &block)
    time = Benchmark.realtime do
      block.call
    end
    puts "Time to #{label}: " + time.round(2).to_s
  end

  def self.import_nt_file(sub, file_path)
    Goo.sparql_data_client.delete_graph(sub.id)
    Goo.sparql_data_client.append_triples_no_bnodes(sub.id, file_path, nil)
  end

  def self.paginate_all_triples(sub)
    page = 1
    pagesize = 10000
    count = 1
    total_count = 0
    while count > 0 && page < 100
      puts "Starting query for page #{page}"
      offset = " OFFSET #{(page - 1) * pagesize}"
      rs = Goo.sparql_query_client.query("SELECT ?s ?p ?o FROM <#{sub.id}> WHERE {  ?s ?p ?o  } LIMIT #{pagesize} #{offset}")
      count = rs.each_solution.size
      total_count += count
      page += 1
    end
    puts "Total triples: " + total_count.to_s
  end

  def self.ontology_roots(sub)
    load_attrs = LinkedData::Models::Class.goo_attrs_to_load([:all])
    roots = []
    time = Benchmark.realtime do
      roots = sub.roots(load_attrs)
    end
    puts "Time to find roots: " + time.round(2).to_s
    Goo.log_debug_file('roots')
    time = Benchmark.realtime do
      LinkedData::Models::Class.in(sub).models(roots).include(:unmapped).all
    end
    puts "Time to load roots: " + time.round(2).to_s
    Goo.log_debug_file('roots')
    puts "Roots count: " + roots.length.to_s
    puts "Roots total triples: " + roots.map { |r| r.properties.values.flatten.size}.sum.to_s
  end

  def self.concept_children(uri, sub)
    page, size = [1, 100]
    cls = LinkedData::Models::Class.find(RDF::URI.new("http://terminologies.gfbio.org/ITIS/Taxa_0")).in(sub).first
    ld = LinkedData::Models::Class.goo_attrs_to_load([:all])
    children = sub.children(cls, includes_param: ld, page: page, size: size)
    puts "Children count: " + children.length.to_s
  end

  def self.concept_tree(uri, sub)
    cls = LinkedData::Models::Class.find("http://terminologies.gfbio.org/ITIS/Taxa_6007").in(sub).first
    display_attrs = [:prefLabel, :hasChildren, :children, :obsolete, :subClassOf]
    extra_include = display_attrs + [:hasChildren, :isInActiveScheme, :isInActiveScheme]

    roots = sub.roots(extra_include)
    # path = cls.path_to_root(roots)
    cls.tree(roots: roots)
  end

end
