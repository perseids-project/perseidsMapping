#!/usr/bin/perl
# Sample conversion of data from https://github.com/OpenGreekAndLatin/DigitalAthenaeus/blob/master/homer/htr.csv
# to represent these analyses as lawd:TextReuse assertions which can be serialized using Open Annotation
#
# the sample data is intended to populate a CITE collection but did not include the CITE collection URNs
# or identification of the creator of the analyses, so this need to be supplied as input to this
# script so that the output can include URIs for each analyses and for the creator as a prov:Agent
# acting in the lawd:ObserverAssociation role.
#
# Mapping followed the rules set forth in https://github.com/perseids-project/perseidsMapping/blob/master/mapping.rdf
# but made some changes:
#   1. the lawd:TextReuse itself is now mapped to be a subproperty of oa:hasBody - using just the urn of the reused text wasn't
#      expressive enough because we wanted to the reused text and its relationship to the original citation 
#      (the reused text not necessarily equivalent to the URN subreference)
#   2. mapping is condensed to exclude the subclass of lawd:Observation which restricted it to only those Observations made by
#      a specific named agent. This might still be useful to do in the future.
#
# Script was produced during for the Scholarly Communication Institute http://trianglesci.org/
# @Author Bridget Almas
# Licensed under version 3 of the GNU General Public License


use strict;
use Text::CSV;
use Text::CSV::Encoded;
use Encode;
use Data::Dumper;
use URI::Escape;
use UUID ':all';
use utf8;

my $file = $ARGV[0]; # the input CSV file
my $collection = $ARGV[1]; # the CITE collection urn 
my $creator = $ARGV[2]; # the creator URI
my $lang = $ARGV[3]; # the language of the text reuse snippets
my $includeOa = $ARGV[4]; # flag to include OA annotation wrappers in output

# Check input arguments
unless ($file && -f $file) { 
    printUsage("Supply a valid file name that contains the analysis in CSV format\n");
}

unless ($collection =~ /^urn:cite:.*?:[^.]+$/) { 
    printUsage("$collection is not a valid URN");
}

unless ($creator =~ /^https?:/) { 
    printUsage("$creator is not a valid Creator URI");
}

unless ($lang) {
   printUsage("Supply a language for the text reuse snippets");
}

my $csv = Text::CSV::Encoded->new({ encoding_in => "UTF-8", encoding_out => "UTF-8", binary => 1, eol => $/});

my @reuse = ();
my %contextualWorks = ();
my %writtenWorks = ();
my %citations = ();

# Assumes data input with the following columns
#ReusedInUrn,ReusedText,ReusedFromPassageUrn,RusedFromCitationUrn
open my $io, "<", $file or die "$file: $!\n";
my %works = ();
my @textreuses = ();
while (my $row = $csv->getline ($io)) {
    my @fields = @$row;
    my $reuseIn = $fields[0];
    my $reuseValue = $fields[1];
    my $reuseFrom = $fields[3];
    next unless $reuseIn =~ /urn:cts/;
    next unless $reuseIn && $reuseFrom;
    parseUrn($reuseIn);
    parseUrn($reuseFrom);
    $reuseFrom =  escapeUrn($reuseFrom);
    $reuseIn = escapeUrn($reuseIn);
    my $reuse = { "reuseFrom" => $reuseFrom, "reuseIn", => $reuseIn, "value" => $reuseValue };
    push @reuse, $reuse;
}


# Print the RDF Prefixes and Mapping of TextReuse as a subproperty of oa:hasBody
print <<"EOS";
\@prefix lawd: <http://lawd.info/ontology/> .
\@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
\@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
\@prefix oa: <http://www.w3.org/ns/oa#> .

<http://lawd.info/ontology/TextReuse> rdfs:subPropertyOf <http://www.w3.org/ns/oa#hasBody> .

EOS


# Print the the observer role association
# Note that if you have per annotation creator information, there would need to be
# one set for each annotator
# just use a general uuid for these for now
my $uuid;
generate($uuid);
my $obs = "";
unparse($uuid,$obs);
$obs = "urn:uuid:$obs";
print <<"EOS";
<$obs> rdf:type <http://lawd.info/ontology/ObserverRoleAssociation>; 
  <http://www.w3.org/ns/prov#agent> <$creator>.

<$creator> rdf:type <http://lawd.info/ontology/Person>.

EOS

# Iterate through the reuse analyses and output them as RDF statements
for (my $i=0; $i<@reuse.length; $i++) {
    # just assign a sequential urn to each collection item for now
    # just use a dummy URI for the annotations for now, which appends the /oa path onto the CITE URN
    my $id = $i+1;
    if ($includeOa) {
        print <<"EOS";
<$collection.$id/oa> a oa:Annotation;
  oa:hasBody <$collection.$id>;
  oa:hasTarget <$reuse[$i]{'reuseIn'}>.

EOS
    }

# Print the CTS URN expansion into the lawd entities
        print <<"EOS";
<$collection.$id> rdf:type <http://lawd.info/ontology/TextReuse> ;
    <http://lawd.info/ontology/reuseIn> <$reuse[$i]{'reuseIn'}> ;
    <http://lawd.info/ontology/reuseFrom> <$reuse[$i]{'reuseFrom'}> ;
    rdf:value "$reuse[$i]{'value'}"\@$lang ; 
    <http://www.w3.org/ns/prov#qualifiedAssociation> <$obs> .

EOS
}

foreach my $urn (sort keys %writtenWorks) {
    print <<"EOS";
<$urn>  rdf:type <http://lawd.info/ontology/WrittenWork> ;
    <http://lawd.info/ontology/embodies> <$writtenWorks{$urn}> .

EOS
}

foreach my $urn (sort keys %contextualWorks) {
    print <<"EOS";
<$urn>  rdf:type <http://lawd.info/ontology/ConceptualWork> .

EOS
}

foreach my $urn (sort keys %citations) {
    print <<"EOS";
<$urn>  rdf:type <http://lawd.info/ontology/Citation> ;
    <http://lawd.info/ontology/represents> <$citations{$urn}> .

EOS

}
   

# parses a CTS URN into LAWD entities
sub parseUrn {
    my $urn = shift;

    my (@parts) = $urn =~/^((((urn:cts:.*?:[^:\.]+)\.[^:\.]+)\.[^:]+)(\:.*?(\@.*?)?)?)$/;
    # $1 = the full urn
    # $2 = the version urn lawd:WrittenWork
    # $3 = the work urn = lawd:ContextualWork
    # $4 = the text group
    # $5 = if defined we have a lawd:Citation
    if ($1) {
        $contextualWorks{escapeUrn($3)} = 1;
        $writtenWorks{escapeUrn($2)} = escapeUrn($3);
        if ($5) {
            $citations{escapeUrn($1)} = escapeUrn($2);
        }
    }
}

#escapses a CTS URN for URI compliance 
sub escapeUrn {
    my $urn = shift;
    $urn =~ s/\[/%5B/g;
    $urn =~ s/\]/%5D/g;
    #$urn =~ s/(@.*)$/uri_escape_utf8($1)/e;
    return $urn;
}

# print script usage statement
sub printUsage {
    my $error = shift;
    print "Error: $error\n";
    print "Usage: $0 <input file> <cite collection urn> <creator> <lang> [1 to print OA]\n";
    exit 1;
}
