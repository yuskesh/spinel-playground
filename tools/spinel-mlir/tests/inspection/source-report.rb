require_relative '../../scripts/lib/inspection-report'
expected="{\n  \"source\": \"x.rb\",\n  \"roots\": [],\n  \"functions\": [],\n  \"edges\": [],\n  \"diagnostics\": []\n}\n"
actual=InspectionReport.go_json({'source'=>'x.rb','roots'=>[],'functions'=>[],'edges'=>[],'diagnostics'=>[]})
raise 'empty graph Go JSON shape' unless actual==expected
raise 'HTML escapes' unless InspectionReport.go_json({'x'=>'<>&'}).include?('\\u003c\\u003e\\u0026')
raise 'literal brackets changed' unless InspectionReport.go_json({'x'=>'[ ]'}).include?('"[ ]"')
raise 'JS separators' unless InspectionReport.go_json({'x'=>"\u2028\u2029"}).include?('\\u2028\\u2029')
puts 'source inspection writer GREEN'
